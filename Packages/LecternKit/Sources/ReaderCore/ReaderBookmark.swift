import CoreGraphics
import Foundation

/// A reader bookmark (A2, spec §5.2): a named place in a document, kept on
/// this Mac in the document's stored state and never written into the PDF.
public struct ReaderBookmark: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// Where the bookmark points: the reading anchor when it was made.
    public var anchor: ReadingAnchor
    public var created: Date

    public init(id: UUID = UUID(), name: String, anchor: ReadingAnchor, created: Date = Date()) {
        self.id = id
        self.name = name
        self.anchor = anchor
        self.created = created
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, anchor, created
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? ""
        anchor = try container.decode(ReadingAnchor.self, forKey: .anchor)
        created = (try? container.decodeIfPresent(Date.self, forKey: .created)) ?? .distantPast
    }

    /// The same bookmark on a document with `pageCount` pages (A2: remap by
    /// page, clamp).
    public func clamped(toPageCount pageCount: Int) -> ReaderBookmark {
        var copy = self
        copy.anchor = anchor.clamped(toPageCount: pageCount)
        return copy
    }
}

/// The rules for a document's bookmarks.
public enum ReaderBookmarks {
    /// Reading order: by page, then from the top of the page down (page
    /// space has y growing upwards), then by when they were made.
    public static func sorted(_ bookmarks: [ReaderBookmark]) -> [ReaderBookmark] {
        bookmarks.sorted { a, b in
            if a.anchor.pageIndex != b.anchor.pageIndex { return a.anchor.pageIndex < b.anchor.pageIndex }
            if a.anchor.pointInPage.y != b.anchor.pointInPage.y { return a.anchor.pointInPage.y > b.anchor.pointInPage.y }
            return a.created < b.created
        }
    }

    /// "A bookmark here" means a bookmark on the page being read (as shown in a document with
    /// `pageCount` pages): ⌘D removes it instead of adding a second one, as in Preview.
    public static func bookmarks(onPageOf anchor: ReadingAnchor, in bookmarks: [ReaderBookmark], pageCount: Int = .max) -> [ReaderBookmark] {
        bookmarks.filter { $0.anchor.clamped(toPageCount: pageCount).pageIndex == anchor.pageIndex }
    }

    /// The bookmark on the anchor's page nearest the anchor: the one ⌘D removes.
    public static func nearest(to anchor: ReadingAnchor, in bookmarks: [ReaderBookmark], pageCount: Int = .max) -> ReaderBookmark? {
        Self.bookmarks(onPageOf: anchor, in: bookmarks, pageCount: pageCount).min { a, b in
            distance(a.anchor, anchor) < distance(b.anchor, anchor)
        }
    }

    private static func distance(_ a: ReadingAnchor, _ b: ReadingAnchor) -> CGFloat {
        hypot(a.pointInPage.x - b.pointInPage.x, a.pointInPage.y - b.pointInPage.y)
    }

    /// What ⌘D did.
    public enum Toggle: Equatable, Sendable {
        case added(ReaderBookmark)
        case removed(ReaderBookmark)
    }

    /// Add or remove: removes the one bookmark on the anchor's page nearest the anchor if there
    /// is one, otherwise adds one at the anchor, named `name`. Never removes more than one.
    public static func toggle(at anchor: ReadingAnchor, name: String, in bookmarks: inout [ReaderBookmark], pageCount: Int = .max, now: Date = Date()) -> Toggle {
        if let nearest = nearest(to: anchor, in: bookmarks, pageCount: pageCount) {
            bookmarks.removeAll { $0.id == nearest.id }
            return .removed(nearest)
        }
        let added = ReaderBookmark(name: name, anchor: anchor, created: now)
        bookmarks = sorted(bookmarks + [added])
        return .added(added)
    }

    /// The name a new bookmark gets.
    public static func defaultName(pageLabel: String) -> String {
        "Page \(pageLabel)"
    }

    /// A rename keeps the old name when the new one is blank.
    public static func renamed(_ id: UUID, to name: String, in bookmarks: [ReaderBookmark]) -> [ReaderBookmark] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return bookmarks }
        return bookmarks.map { bookmark in
            guard bookmark.id == id else { return bookmark }
            var copy = bookmark
            copy.name = trimmed
            return copy
        }
    }
}

/// The JSON a document's bookmarks are exported as (A2: not locked in).
/// The schema is documented in docs/bookmarks-export.md; `version` changes
/// only when a field changes meaning or goes away. New optional fields may be
/// added within a version.
public struct BookmarkExport: Codable, Equatable, Sendable {
    public static let formatName = "io.github.ronimoe.lectern.bookmarks"
    public static let currentVersion = 1

    public struct Document: Codable, Equatable, Sendable {
        /// The PDF's `/Title`, or the file name without its extension when it has none.
        public var title: String
        public var fileName: String
        /// The trailer's `/ID` pair as lowercase hex; empty when the file has none.
        public var id: [String]
        public var pageCount: Int

        public init(title: String, fileName: String, id: [String], pageCount: Int) {
            self.title = title
            self.fileName = fileName
            self.id = id
            self.pageCount = pageCount
        }
    }

    public struct Anchor: Codable, Equatable, Sendable {
        /// A point in the page's own coordinate space (PDF points, origin at
        /// the bottom left of the unrotated crop box, y upwards): the point at
        /// the top-left corner of the reading area when the bookmark was made.
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    public struct Bookmark: Codable, Equatable, Sendable {
        public var name: String
        /// Zero-based.
        public var pageIndex: Int
        /// The page's label (`/PageLabels`), or its one-based number.
        public var pageLabel: String
        public var anchor: Anchor
        public var created: Date

        public init(name: String, pageIndex: Int, pageLabel: String, anchor: Anchor, created: Date) {
            self.name = name
            self.pageIndex = pageIndex
            self.pageLabel = pageLabel
            self.anchor = anchor
            self.created = created
        }
    }

    public var format: String
    public var version: Int
    public var exported: Date
    public var document: Document
    public var bookmarks: [Bookmark]

    public init(document: Document, bookmarks: [ReaderBookmark], pageLabel: (Int) -> String, exported: Date = Date()) {
        format = Self.formatName
        version = Self.currentVersion
        self.exported = exported
        self.document = document
        self.bookmarks = ReaderBookmarks.sorted(bookmarks).map { bookmark in
            Bookmark(
                name: bookmark.name,
                pageIndex: bookmark.anchor.pageIndex,
                pageLabel: pageLabel(bookmark.anchor.pageIndex),
                anchor: Anchor(x: Double(bookmark.anchor.pointInPage.x), y: Double(bookmark.anchor.pointInPage.y)),
                created: bookmark.created
            )
        }
    }

    /// Pretty-printed, sorted keys, ISO 8601 dates.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> BookmarkExport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BookmarkExport.self, from: data)
    }

    /// "<name> Bookmarks.json"
    public static func suggestedFileName(forDocumentNamed name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        return "\(base.isEmpty ? "Document" : base) Bookmarks.json"
    }
}

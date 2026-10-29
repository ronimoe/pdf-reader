import CoreGraphics
import CryptoKit
import Foundation

/// How a document is recognised the next time it opens (decision A2).
///
/// - **Primary:** the security-scoped file bookmark, which follows moves and
///   renames.
/// - **Fallback:** the PDF's `/ID`, when the bookmark no longer resolves.
///
/// The fingerprint tells an unchanged file from one that changed at the same
/// place, so stored positions can be remapped.
public struct DocumentIdentity: Codable, Hashable, Sendable {
    /// Security-scoped bookmark data for the file.
    public var bookmark: Data?
    /// The trailer's `/ID` pair as hex: the first element is permanent, the
    /// second changes when the file is modified. Empty when the file has none.
    public var fileIdentifiers: [String]
    public var pageCount: Int
    public var fileSize: Int
    public var lastKnownPath: String
    /// A hash of the file's size and its first and last 64 KB. The tail holds
    /// the newest trailer and cross-reference section, so any edit changes it.
    public var fingerprint: String
    /// The file's volume and file number ("device:inode"). A rename or a move
    /// within the volume keeps it, so it finds the record whose bookmark to
    /// resolve without resolving every bookmark on record.
    public var fileNumber: String?

    public init(
        bookmark: Data?,
        fileIdentifiers: [String],
        pageCount: Int,
        fileSize: Int,
        lastKnownPath: String,
        fingerprint: String,
        fileNumber: String? = nil
    ) {
        self.bookmark = bookmark
        self.fileIdentifiers = fileIdentifiers
        self.pageCount = pageCount
        self.fileSize = fileSize
        self.lastKnownPath = lastKnownPath
        self.fingerprint = fingerprint
        self.fileNumber = fileNumber
    }

    /// The permanent half of `/ID`, which a duplicated file shares.
    public var permanentIdentifier: String? { fileIdentifiers.first }

    private enum CodingKeys: String, CodingKey {
        case bookmark, fileIdentifiers, pageCount, fileSize, lastKnownPath, fingerprint, fileNumber
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bookmark = try container.decodeIfPresent(Data.self, forKey: .bookmark)
        fileIdentifiers = try container.decodeIfPresent([String].self, forKey: .fileIdentifiers) ?? []
        pageCount = try container.decodeIfPresent(Int.self, forKey: .pageCount) ?? 0
        fileSize = try container.decodeIfPresent(Int.self, forKey: .fileSize) ?? 0
        lastKnownPath = try container.decodeIfPresent(String.self, forKey: .lastKnownPath) ?? ""
        fingerprint = try container.decodeIfPresent(String.self, forKey: .fingerprint) ?? ""
        fileNumber = try container.decodeIfPresent(String.self, forKey: .fileNumber)
    }

    // MARK: Reading a file

    /// The `/ID` pair as hex, readable while the document is locked.
    public static func fileIdentifiers(ofPDF data: Data) -> [String] {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider)
        else { return [] }
        return fileIdentifiers(of: document)
    }

    /// The same, from a document that is already parsed.
    public static func fileIdentifiers(of document: CGPDFDocument) -> [String] {
        guard let array = document.fileIdentifier else { return [] }
        var result: [String] = []
        for index in 0..<CGPDFArrayGetCount(array) {
            var string: CGPDFStringRef?
            guard CGPDFArrayGetString(array, index, &string), let string,
                  let bytes = CGPDFStringGetBytePtr(string)
            else { return result }
            let length = CGPDFStringGetLength(string)
            result.append(DocumentKey.hex(Data(bytes: bytes, count: length)))
        }
        return result
    }

    /// "device:inode" for the file at `url`, or nil if it can't be read.
    public static func fileNumber(of url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber
        else { return nil }
        return "\(device.uint64Value):\(inode.uint64Value)"
    }

    public static let fingerprintSpan = 64 * 1024

    public static func fingerprint(of data: Data) -> String {
        var hasher = SHA256()
        withUnsafeBytes(of: UInt64(data.count).littleEndian) { hasher.update(bufferPointer: $0) }
        hasher.update(data: data.prefix(fingerprintSpan))
        hasher.update(data: data.suffix(fingerprintSpan))
        return DocumentKey.hex(Data(hasher.finalize()))
    }
}

/// Decides which stored record, if any, a file that is opening belongs to
/// (A2). Pure logic: the caller resolves the candidates' bookmarks.
public enum DocumentMatcher {
    public struct Candidate: Hashable, Sendable {
        public var id: UUID
        public var identity: DocumentIdentity
        public var lastOpened: Date
        /// Where the candidate's bookmark resolves now, or nil if it doesn't.
        public var resolvedPath: String?

        public init(id: UUID, identity: DocumentIdentity, lastOpened: Date, resolvedPath: String?) {
            self.id = id
            self.identity = identity
            self.lastOpened = lastOpened
            self.resolvedPath = resolvedPath
        }
    }

    public enum Match: Hashable, Sendable {
        /// The same document. `contentChanged` means the file was modified
        /// since it was last seen, so positions are remapped by page.
        case same(UUID, contentChanged: Bool)
        /// Another file with this document's `/ID` exists: a duplicate,
        /// which starts from the original's state and diverges from it.
        case duplicate(of: UUID)
        case new
    }

    /// - Parameters:
    ///   - path: the opening file's standardized path.
    ///   - identity: the opening file's identity (its bookmark isn't used).
    ///   - candidates: stored records, with their bookmarks resolved.
    public static func match(path: String, identity: DocumentIdentity, candidates: [Candidate]) -> Match {
        let newestFirst = candidates.sorted { $0.lastOpened > $1.lastOpened }

        // 1. The bookmark resolves to this file: the same document, wherever
        //    it has moved to or been renamed.
        if let byBookmark = newestFirst.first(where: { $0.resolvedPath == path }) {
            return .same(byBookmark.id, contentChanged: byBookmark.identity.fingerprint != identity.fingerprint)
        }

        // 2. Fallback: the permanent /ID, or identical content for files
        //    without one.
        let sameDocument = newestFirst.filter { candidate in
            if let permanent = identity.permanentIdentifier {
                return candidate.identity.permanentIdentifier == permanent
            }
            return candidate.identity.fingerprint == identity.fingerprint
        }
        guard let original = sameDocument.first else { return .new }
        if original.resolvedPath == nil {
            // The original's bookmark no longer resolves (moved somewhere it
            // can't follow, or replaced): this file takes its place.
            return .same(original.id, contentChanged: original.identity.fingerprint != identity.fingerprint)
        }
        // The original still exists elsewhere, so this is a copy of it.
        return .duplicate(of: original.id)
    }
}

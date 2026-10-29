import Foundation

public enum PDFSaveError: Error, Equatable, Sendable {
    /// The file has an `/Encrypt` dictionary. New objects would have to be encrypted with the
    /// document key, which the writer doesn't do. In v1 these files can't be saved with annotations.
    case encrypted
    /// The file's structure can't be trusted (bad xref offsets, broken trailer chain, …). The
    /// writer never appends on top of a guessed cross-reference.
    case malformed(String)
    /// Valid PDF, but uses something this writer deliberately doesn't handle.
    case unsupported(String)
    /// `saveInPlace` was asked to modify a document that may only be saved as a copy
    /// (signed, certified or Reader-extended). Use `saveCopy` and write to a new file.
    case copyOnly([CopyOnlyReason])
    case pageOutOfRange(Int)
    case annotationNotFound(ObjectRef)
    /// A new annotation's `/NM` is already used in the file or by another change in the same save.
    case duplicateName(String)
    /// The saved bytes did not re-parse to what was written. Nothing should be written to disk.
    case verificationFailed(String)
}

public struct PDFPoint: Sendable, Equatable, Hashable, Codable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// A rectangle in default user space (PDF points, y up).
public struct PDFRect: Sendable, Equatable, Hashable, Codable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    /// The rectangle spanned by two opposite corners in any order, as a PDF `/Rect` array stores
    /// them (`[x1 y1 x2 y2]` need not be lower-left first).
    public init(corners x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        self.init(x: min(x1, x2), y: min(y1, y2), width: abs(x2 - x1), height: abs(y2 - y1))
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    /// The same rectangle with a non-negative width and height.
    public var standardized: PDFRect { PDFRect(corners: x, y, maxX, maxY) }

    /// True when every edge of `self` is within `tolerance` points of the same edge of `other`.
    public func isClose(to other: PDFRect, tolerance: Double) -> Bool {
        let a = standardized, b = other.standardized
        return abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
            && abs(a.maxX - b.maxX) <= tolerance && abs(a.maxY - b.maxY) <= tolerance
    }
}

/// One quadrilateral of a text-markup annotation, in default user space (PDF points, y up).
/// The order follows what Acrobat, PDFKit and pdf.js write: upper-left, upper-right,
/// lower-left, lower-right.
public struct Quad: Sendable, Equatable, Hashable, Codable {
    public var upperLeft: PDFPoint, upperRight: PDFPoint, lowerLeft: PDFPoint, lowerRight: PDFPoint

    public init(upperLeft: PDFPoint, upperRight: PDFPoint, lowerLeft: PDFPoint, lowerRight: PDFPoint) {
        self.upperLeft = upperLeft; self.upperRight = upperRight
        self.lowerLeft = lowerLeft; self.lowerRight = lowerRight
    }

    /// An axis-aligned quad covering `rect`.
    public init(rect: PDFRect) {
        self.init(upperLeft: PDFPoint(x: rect.x, y: rect.maxY), upperRight: PDFPoint(x: rect.maxX, y: rect.maxY),
                  lowerLeft: PDFPoint(x: rect.x, y: rect.y), lowerRight: PDFPoint(x: rect.maxX, y: rect.y))
    }

    var points: [PDFPoint] { [upperLeft, upperRight, lowerLeft, lowerRight] }

    /// The smallest rectangle containing every corner.
    public var bounds: PDFRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        return PDFRect(corners: xs.min()!, ys.min()!, xs.max()!, ys.max()!)
    }
}

/// An RGB colour with components in 0…1, as written to `/C`.
public struct PDFRGBColor: Sendable, Equatable, Hashable, Codable {
    public var red: Double, green: Double, blue: Double
    public init(red: Double, green: Double, blue: Double) { self.red = red; self.green = green; self.blue = blue }
    public static let yellow = PDFRGBColor(red: 1, green: 0.85, blue: 0)
}

/// The three text-markup kinds (B4). They differ only in shape, not in what they store.
public enum MarkupKind: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case highlight = "Highlight"
    case underline = "Underline"
    case strikeOut = "StrikeOut"

    /// The annotation `/Subtype`.
    public var subtype: String { rawValue }
}

/// Unique `/NM` values for annotations Lectern creates.
public enum AnnotationName {
    public static let prefix = "lectern-"

    /// `lectern-<lowercase UUID>`.
    public static func generate() -> String { prefix + UUID().uuidString.lowercased() }

    /// True for names this app generated, so their annotations can be matched exactly.
    public static func isLectern(_ name: String?) -> Bool { name?.hasPrefix(prefix) ?? false }
}

/// A new highlight, underline or strike-out.
///
/// Nothing personal is written unless it is passed here (B4): `/T` only when `author` is
/// non-empty, and no dates at all unless `IncrementalWriter.Options.modificationDate` is set.
public struct NewMarkup: Sendable, Equatable, Hashable, Codable {
    public var kind: MarkupKind
    public var pageIndex: Int
    public var quads: [Quad]
    public var color: PDFRGBColor
    /// `/Contents`: the comment on the markup (B4).
    public var contents: String?
    /// `/T`. Empty by default (B4); only set when the user configured an author name.
    public var author: String?
    /// `/NM`. Fixed when the change is created, so the journal replays it unchanged and the app can
    /// give the same name to its in-memory annotation to match it after the save.
    public var name: String

    public init(kind: MarkupKind, pageIndex: Int, quads: [Quad], color: PDFRGBColor = .yellow,
                contents: String? = nil, author: String? = nil, name: String = AnnotationName.generate()) {
        self.kind = kind; self.pageIndex = pageIndex; self.quads = quads; self.color = color
        self.contents = contents; self.author = author; self.name = name
    }
}

/// A new sticky note (`/Subtype /Text`) with a 20×20 icon.
public struct NewNote: Sendable, Equatable, Hashable, Codable {
    public var pageIndex: Int
    /// Where the icon goes; the lower-left corner in default user space.
    public var origin: PDFPoint
    public var color: PDFRGBColor
    public var contents: String?
    public var author: String?
    public var name: String

    public init(pageIndex: Int, origin: PDFPoint, color: PDFRGBColor = .yellow, contents: String?,
                author: String? = nil, name: String = AnnotationName.generate()) {
        self.pageIndex = pageIndex; self.origin = origin; self.color = color
        self.contents = contents; self.author = author; self.name = name
    }
}

/// One annotation change, with everything needed to replay it. Codable, so the app's crash journal
/// can store the unsaved list (architecture §6). Existing annotations are addressed by `ObjectRef`,
/// which is only meaningful for the exact file bytes it was read from.
public enum AnnotationChange: Sendable, Equatable, Hashable, Codable {
    case addMarkup(NewMarkup)
    case addNote(NewNote)
    /// Replace (or with nil remove) `/Contents`. Also drops `/RC`, the rich-text copy that
    /// Acrobat shows instead of `/Contents`; a FreeText annotation also loses its stale `/AP`.
    case editContents(ObjectRef, String?)
    /// Replace `/C`. The appearance is regenerated for highlights, underlines, strike-outs and our
    /// own notes; see `IncrementalWriter` for the other subtypes.
    case editColor(ObjectRef, PDFRGBColor)
    /// Remove an existing annotation (with its `/Popup` and replies) from its page's `/Annots`.
    case delete(ObjectRef)
}

/// A new annotation as written.
public struct AddedAnnotation: Sendable, Equatable, Hashable {
    public let ref: ObjectRef
    public let pageIndex: Int
    public let subtype: String
    /// The `/NM` written, the same as the change's `name`.
    public let name: String
}

/// What a save produced, for the caller's post-save checks and for tests.
public struct SaveResult: Sendable {
    public let data: Data
    /// The original length; `data.prefix(originalLength)` is the untouched original.
    public let originalLength: Int
    public let xrefKind: XRefKind
    /// New annotation objects, in the order of the `add…` changes.
    public let added: [AddedAnnotation]
    /// Existing objects written again with new content (pages, `/Annots` arrays, edited annotations).
    public let rewrittenObjects: [ObjectRef]
    /// Every object written in the update, new or rewritten, including appearance streams.
    public let writtenObjects: [ObjectRef]
    /// References removed from `/Annots` arrays (deleted annotations and their popups/replies).
    public let removedAnnotations: [ObjectRef]

    public var addedAnnotations: [ObjectRef] { added.map(\.ref) }
}

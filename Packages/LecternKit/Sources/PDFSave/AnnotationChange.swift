import Foundation

public enum PDFSaveError: Error, Equatable, Sendable {
    /// The file has an `/Encrypt` dictionary. New objects would have to be encrypted with the
    /// document key, which the writer doesn't do; the app routes these files to Save a Copy.
    case encrypted
    /// The file's structure can't be trusted (bad xref offsets, broken trailer chain, …). The
    /// writer never appends on top of a guessed cross-reference; route to Save a Copy.
    case malformed(String)
    /// Valid PDF, but uses something this writer deliberately doesn't handle.
    case unsupported(String)
    case pageOutOfRange(Int)
    case annotationNotFound(ObjectRef)
    /// The saved bytes did not re-parse to what was written. Nothing should be written to disk.
    case verificationFailed(String)
}

public struct PDFPoint: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct PDFRect: Sendable, Equatable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
}

/// One quadrilateral of a text-markup annotation, in default user space (PDF points, y up).
/// The order follows what Acrobat, PDFKit and pdf.js write: upper-left, upper-right,
/// lower-left, lower-right.
public struct Quad: Sendable, Equatable {
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
}

public struct RGBColor: Sendable, Equatable {
    public var red: Double, green: Double, blue: Double
    public init(red: Double, green: Double, blue: Double) { self.red = red; self.green = green; self.blue = blue }
    public static let yellow = RGBColor(red: 1, green: 0.85, blue: 0)
}

public struct NewHighlight: Sendable, Equatable {
    public var pageIndex: Int
    public var quads: [Quad]
    public var color: RGBColor
    public var contents: String?
    /// `/T`. Empty by default (B4); only set when the user configured an author name.
    public var author: String?

    public init(pageIndex: Int, quads: [Quad], color: RGBColor = .yellow, contents: String? = nil, author: String? = nil) {
        self.pageIndex = pageIndex; self.quads = quads; self.color = color
        self.contents = contents; self.author = author
    }
}

public struct NewNote: Sendable, Equatable {
    public var pageIndex: Int
    /// Where the icon goes; the lower-left corner in default user space.
    public var origin: PDFPoint
    public var color: RGBColor
    public var contents: String
    public var author: String?

    public init(pageIndex: Int, origin: PDFPoint, color: RGBColor = .yellow, contents: String, author: String? = nil) {
        self.pageIndex = pageIndex; self.origin = origin; self.color = color
        self.contents = contents; self.author = author
    }
}

public enum AnnotationChange: Sendable, Equatable {
    case addHighlight(NewHighlight)
    case addNote(NewNote)
    /// Replace `/Contents` of an existing annotation, addressed by object reference.
    case editContents(ObjectRef, String)
    /// Remove an existing annotation (with its `/Popup` and replies) from its page's `/Annots`.
    case delete(ObjectRef)
}

/// What a save produced, for the caller's post-save checks and for tests.
public struct SaveResult: Sendable {
    public let data: Data
    /// The original length; `data.prefix(originalLength)` is the untouched original.
    public let originalLength: Int
    public let xrefKind: XRefKind
    /// New annotation objects, in the order of the `add…` changes.
    public let addedAnnotations: [ObjectRef]
    /// Existing objects written again with new content (pages, `/Annots` arrays, edited annotations).
    public let rewrittenObjects: [ObjectRef]
    /// Every object written in the update, new or rewritten, including appearance streams.
    public let writtenObjects: [ObjectRef]
    /// References removed from `/Annots` arrays (deleted annotations and their popups/replies).
    public let removedAnnotations: [ObjectRef]
}

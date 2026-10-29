import Foundation

/// An annotation's `/C` colour, in whichever colour space the file uses (0, 1, 3 or 4 components).
public enum AnnotationColor: Sendable, Equatable, Hashable {
    /// `/C []`: no colour.
    case transparent
    case gray(Double)
    case rgb(PDFRGBColor)
    case cmyk(cyan: Double, magenta: Double, yellow: Double, black: Double)

    /// Reads a `/C` array; nil for any other component count.
    init?(components c: [Double]) {
        switch c.count {
        case 0: self = .transparent
        case 1: self = .gray(c[0])
        case 3: self = .rgb(PDFRGBColor(red: c[0], green: c[1], blue: c[2]))
        case 4: self = .cmyk(cyan: c[0], magenta: c[1], yellow: c[2], black: c[3])
        default: return nil
        }
    }

    /// An RGB approximation (naive CMYK conversion), or nil when transparent.
    public var rgb: PDFRGBColor? {
        switch self {
        case .transparent: nil
        case .gray(let g): PDFRGBColor(red: g, green: g, blue: g)
        case .rgb(let c): c
        case .cmyk(let c, let m, let y, let k):
            PDFRGBColor(red: (1 - c) * (1 - k), green: (1 - m) * (1 - k), blue: (1 - y) * (1 - k))
        }
    }
}

/// What the file says about one annotation. The app uses these to map PDFKit's `PDFAnnotation`
/// objects to file objects (`AnnotationMatcher`), and edits and deletes address them by `ref`.
public struct AnnotationDescriptor: Sendable, Equatable, Hashable {
    /// The annotation's object. Nil for an annotation dictionary written inline in `/Annots`,
    /// which has no object number and so can't be edited or deleted.
    public let ref: ObjectRef?
    public let pageIndex: Int
    /// Position in the page's `/Annots` array.
    public let indexInAnnots: Int
    /// `/Subtype` without the slash, e.g. "Highlight"; empty if missing.
    public let subtype: String
    /// `/Rect`, standardized; nil if missing or not four numbers.
    public let rect: PDFRect?
    /// `/NM`.
    public let name: String?
    public let contents: String?
    /// `/T`.
    public let author: String?
    /// `/IRT`: the annotation this one replies to.
    public let inReplyTo: ObjectRef?
    /// `/Popup`.
    public let popup: ObjectRef?
    /// `/C`.
    public let color: AnnotationColor?

    /// True when Lectern created this annotation (its `/NM` has our prefix).
    public var isLectern: Bool { AnnotationName.isLectern(name) }
}

/// The app's side of a match: what PDFKit reports for one `PDFAnnotation`.
public struct AnnotationQuery: Sendable, Equatable, Hashable {
    public var pageIndex: Int
    /// PDFKit's `type`, e.g. "Highlight" (a leading slash is ignored).
    public var subtype: String
    /// PDFKit's `bounds`.
    public var rect: PDFRect
    public var contents: String?
    /// The `/NM` value (`PDFAnnotationKey.name`), if the annotation has one.
    public var name: String?

    public init(pageIndex: Int, subtype: String, rect: PDFRect, contents: String? = nil, name: String? = nil) {
        self.pageIndex = pageIndex; self.subtype = subtype; self.rect = rect
        self.contents = contents; self.name = name
    }
}

/// The outcome of matching one query. Anything but `.matched` means "don't touch it": the
/// matcher never guesses.
public enum AnnotationMatch: Sendable, Equatable, Hashable {
    public enum Method: Sendable, Equatable, Hashable {
        /// A unique `/NM` on the same page with the same subtype.
        case name
        /// The `/NM` occurs more than once; page, subtype and `/Rect` picked exactly one.
        case nameAndGeometry
        /// Page, subtype and `/Rect` within the tolerance picked exactly one.
        case geometry
        /// Several geometric candidates; exactly one has the same `/Contents`.
        case geometryAndContents
    }

    case matched(ObjectRef, Method)
    /// More than one file annotation fits (or another query claimed the same one, or the `/NM`
    /// sits on another page or subtype). The candidates are listed.
    case ambiguous([ObjectRef])
    /// Nothing in the file fits.
    case notFound
    /// The only fit is an inline annotation dictionary, which can't be addressed.
    case unaddressable

    public var ref: ObjectRef? { if case .matched(let r, _) = self { r } else { nil } }
}

/// Maps PDFKit-side annotations to file objects. A pure function of its inputs.
///
/// Rules, in order:
/// 1. **`/NM`.** A query with a name only ever matches annotations with that name: one on the
///    same page with the same subtype is a match. If the name isn't in the file the result is
///    `.notFound` (it is never retried by position, so an unsaved annotation can't match someone
///    else's); if it's only on another page or subtype, `.ambiguous`.
/// 2. **Geometry.** Otherwise: same page, same subtype, and every `/Rect` edge within `tolerance`
///    (for sticky notes only the top-left corner, because PDFKit resizes their bounds).
///    Several candidates are narrowed by equal `/Contents`; if that doesn't leave exactly one, the
///    result is `.ambiguous`.
/// 3. **One-to-one.** In a batch, a file annotation claimed by more than one query is ambiguous
///    for all of them.
public struct AnnotationMatcher: Sendable {
    /// Maximum difference, in points, for each `/Rect` edge.
    ///
    /// PDFKit's `bounds` equal `/Rect` to within 1e-13 pt on every non-note annotation in the
    /// corpus (about 1,700 of them), so the default only absorbs rounding. It must stay well below
    /// the 0.5 pt spacing of overlapping link rectangles seen in real papers. Match against the
    /// bounds PDFKit reported when the file was opened, not after the user moved something.
    public var tolerance: Double

    public init(tolerance: Double = 0.05) { self.tolerance = tolerance }

    static func normalizedSubtype(_ s: String) -> String { s.hasPrefix("/") ? String(s.dropFirst()) : s }

    /// Contents compare with nil and "" treated alike, since PDFKit reports a missing
    /// `/Contents` as nil or "" depending on the subtype.
    static func sameContents(_ a: String?, _ b: String?) -> Bool { (a ?? "") == (b ?? "") }

    public func match(_ query: AnnotationQuery, in descriptors: [AnnotationDescriptor]) -> AnnotationMatch {
        let subtype = Self.normalizedSubtype(query.subtype)
        func fits(_ d: AnnotationDescriptor) -> Bool { d.pageIndex == query.pageIndex && d.subtype == subtype }
        func close(_ d: AnnotationDescriptor) -> Bool {
            guard let r = d.rect?.standardized else { return false }
            if subtype == "Text" {
                // PDFKit reports every sticky note as 24×24 anchored at the top-left corner of
                // its /Rect (measured: a 20×20 MuPDF note at y 672…692 comes back at 668…692),
                // so only that corner is compared.
                let q = query.rect.standardized
                return abs(r.x - q.x) <= tolerance && abs(r.maxY - q.maxY) <= tolerance
            }
            return r.isClose(to: query.rect, tolerance: tolerance)
        }

        if let name = query.name, !name.isEmpty {
            let named = descriptors.filter { $0.name == name }
            if named.isEmpty { return .notFound }
            let here = named.filter(fits)
            switch here.count {
            case 0: return .ambiguous(named.compactMap(\.ref))
            case 1: return resolved(here[0], .name)
            default:
                let near = here.filter(close)
                return near.count == 1 ? resolved(near[0], .nameAndGeometry) : .ambiguous(here.compactMap(\.ref))
            }
        }

        let candidates = descriptors.filter { fits($0) && close($0) }
        switch candidates.count {
        case 0: return .notFound
        case 1: return resolved(candidates[0], .geometry)
        default:
            let same = candidates.filter { Self.sameContents($0.contents, query.contents) }
            if same.count == 1 { return resolved(same[0], .geometryAndContents) }
            return .ambiguous(candidates.compactMap(\.ref))
        }
    }

    private func resolved(_ d: AnnotationDescriptor, _ method: AnnotationMatch.Method) -> AnnotationMatch {
        guard let ref = d.ref else { return .unaddressable }
        return .matched(ref, method)
    }

    /// Matches every query, then makes the result one-to-one.
    public func match(_ queries: [AnnotationQuery], in descriptors: [AnnotationDescriptor]) -> [AnnotationMatch] {
        let results = queries.map { match($0, in: descriptors) }
        var claims: [ObjectRef: Int] = [:]
        for r in results { if let ref = r.ref { claims[ref, default: 0] += 1 } }
        return results.map { r in
            if let ref = r.ref, claims[ref, default: 0] > 1 { return .ambiguous([ref]) }
            return r
        }
    }
}

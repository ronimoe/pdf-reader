import Foundation

/// Minimal `/AP /N` appearance streams, so readers that don't synthesise appearances still draw
/// the annotation. Streams are written unfiltered to keep the writer free of a deflate encoder.
enum AppearanceStreams {
    static func f(_ v: Double) -> String { PDFObject.format(v) }

    static func color(_ c: PDFRGBColor) -> String { "\(f(c.red)) \(f(c.green)) \(f(c.blue))" }

    static func markup(_ kind: MarkupKind, quads: [Quad], color: PDFRGBColor, bbox: PDFRect) -> PDFStream {
        switch kind {
        case .highlight: highlight(quads: quads, color: color, bbox: bbox)
        // The quads span the line from descender to ascender. An underline sits just below the
        // baseline; a strike-out near the middle of the lower-case letters.
        case .underline: line(quads: quads, color: color, bbox: bbox, at: 0.1)
        case .strikeOut: line(quads: quads, color: color, bbox: bbox, at: 0.45)
        }
    }

    /// One stroked line per quad, parallel to its lower edge at `fraction` of the quad's height,
    /// with a width of 1/14 of the height (at least 0.5 pt). Works for rotated quads too.
    static func line(quads: [Quad], color c: PDFRGBColor, bbox: PDFRect, at fraction: Double) -> PDFStream {
        var ops = ["\(color(c)) RG", "0 J"]
        for q in quads {
            func lerp(_ a: PDFPoint, _ b: PDFPoint, _ t: Double) -> PDFPoint {
                PDFPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            }
            let start = lerp(q.lowerLeft, q.upperLeft, fraction), end = lerp(q.lowerRight, q.upperRight, fraction)
            let height = hypot(q.upperLeft.x - q.lowerLeft.x, q.upperLeft.y - q.lowerLeft.y)
            ops.append("\(f(max(0.5, height / 14))) w")
            ops.append("\(f(start.x)) \(f(start.y)) m \(f(end.x)) \(f(end.y)) l S")
        }
        return form(bbox: [bbox.x, bbox.y, bbox.maxX, bbox.maxY], resources: PDFDictionary(), content: ops)
    }

    /// Fills each quad with the colour using the Multiply blend mode, so text stays readable.
    static func highlight(quads: [Quad], color c: PDFRGBColor, bbox: PDFRect) -> PDFStream {
        var ops = ["/LecternHL gs", "\(color(c)) rg"]
        for q in quads {
            // upper-left → upper-right → lower-right → lower-left
            ops.append("\(f(q.upperLeft.x)) \(f(q.upperLeft.y)) m")
            ops.append("\(f(q.upperRight.x)) \(f(q.upperRight.y)) l")
            ops.append("\(f(q.lowerRight.x)) \(f(q.lowerRight.y)) l")
            ops.append("\(f(q.lowerLeft.x)) \(f(q.lowerLeft.y)) l h")
        }
        ops.append("f")
        let gs: PDFDictionary = ["Type": .name("ExtGState"), "BM": .name("Multiply"), "CA": .integer(1), "ca": .integer(1)]
        let resources: PDFDictionary = ["ExtGState": .dictionary(["LecternHL": .dictionary(gs)])]
        return form(bbox: [bbox.x, bbox.y, bbox.maxX, bbox.maxY], resources: resources, content: ops)
    }

    /// A 20×20 note icon: coloured square with a dark border and three text lines.
    static func note(size: Double, color c: PDFRGBColor) -> PDFStream {
        let s = size
        let ops = [
            "\(color(c)) rg 0.25 0.25 0.25 RG 1 w",
            "0.5 0.5 \(f(s - 1)) \(f(s - 1)) re B",
            "0.25 0.25 0.25 RG 1.2 w",
            "4 \(f(s * 0.72)) m \(f(s - 4)) \(f(s * 0.72)) l S",
            "4 \(f(s * 0.5)) m \(f(s - 4)) \(f(s * 0.5)) l S",
            "4 \(f(s * 0.28)) m \(f(s * 0.65)) \(f(s * 0.28)) l S",
        ]
        return form(bbox: [0, 0, s, s], resources: PDFDictionary(), content: ops)
    }

    private static func form(bbox: [Double], resources: PDFDictionary, content: [String]) -> PDFStream {
        let dict: PDFDictionary = [
            "Type": .name("XObject"), "Subtype": .name("Form"), "FormType": .integer(1),
            "BBox": .array(bbox.map(PDFObject.number)), "Resources": .dictionary(resources),
        ]
        return PDFStream(dictionary: dict, rawData: Array(content.joined(separator: "\n").utf8))
    }
}

extension PDFDictionary: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (PDFName, PDFObject)...) {
        self.init(elements.map { Entry(key: $0.0, value: $0.1) })
    }
}

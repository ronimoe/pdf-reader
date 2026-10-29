import Foundation

/// Minimal `/AP /N` appearance streams, so readers that don't synthesise appearances still draw
/// the annotation. Streams are written unfiltered to keep the writer free of a deflate encoder.
enum AppearanceStreams {
    static func f(_ v: Double) -> String { PDFObject.format(v) }

    static func color(_ c: RGBColor) -> String { "\(f(c.red)) \(f(c.green)) \(f(c.blue))" }

    /// Fills each quad with the colour using the Multiply blend mode, so text stays readable.
    static func highlight(quads: [Quad], color c: RGBColor, bbox: PDFRect) -> PDFStream {
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
    static func note(size: Double, color c: RGBColor) -> PDFStream {
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

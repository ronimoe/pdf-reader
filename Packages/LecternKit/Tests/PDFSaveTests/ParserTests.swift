import Foundation
import Testing
@testable import PDFSave

@Suite struct ParserTests {
    func parse(_ s: String) throws -> PDFObject {
        var p = PDFParser(bytes: Array(s.utf8))
        return try p.parseObject()
    }

    @Test func literalStringEscapes() throws {
        // "x\<LF>y" is a line continuation.
        var p = PDFParser(bytes: Array(#"(a\(b\)c \\ \101\n (nested) x\"#.utf8) + [0x0A] + Array("y)".utf8))
        let o = try p.parseObject()
        #expect(o.stringValue?.bytes == Array("a(b)c \\ A\n (nested) xy".utf8))
    }

    @Test func literalStringNormalisesBareCRLF() throws {
        var p = PDFParser(bytes: Array("(a".utf8) + [0x0D, 0x0A] + Array("b)".utf8))
        #expect(try p.parseObject().stringValue?.bytes == Array("a\nb".utf8))
    }

    @Test func hexStringOddDigits() throws {
        #expect(try parse("<48 65 6C6C 6F7>").stringValue?.bytes == Array("Hello".utf8) + [0x70])
    }

    @Test func nameEscapes() throws {
        #expect(try parse("/A#20B#23").nameValue == PDFName("A B#"))
        #expect(PDFSerializer.bytes(.name(PDFName("A B#"))) == Array("/A#20B#23".utf8))
    }

    @Test func referencesInArrays() throws {
        let o = try parse("[1 0 R 2 3 -4 5.50]")
        #expect(o == .array([.reference(ObjectRef(1, 0)), .integer(2), .integer(3), .integer(-4), .real("5.50")]))
    }

    @Test func dictionaryRoundTripKeepsOrderAndReals() throws {
        let src = "<</Type/Page/MediaBox[0 0 612.00 792]/Rotate 90/Contents 4 0 R/Z(\\(x\\))>>"
        let o = try parse(src)
        let again = try parse(String(decoding: PDFSerializer.bytes(o), as: UTF8.self))
        #expect(o == again)
        #expect(o.dictionaryValue?.keys.map(\.string) == ["Type", "MediaBox", "Rotate", "Contents", "Z"])
        #expect(String(decoding: PDFSerializer.bytes(o), as: UTF8.self).contains("612.00"))
    }

    @Test func textStrings() {
        #expect(PDFString(text: "plain").bytes == Array("plain".utf8))
        let u = PDFString(text: "Zürich ✓")
        #expect(u.isHex && u.bytes.prefix(2) == [0xFE, 0xFF])
        #expect(u.text == "Zürich ✓")
    }

    @Test func inflateZlib() throws {
        let raw = Data(String(repeating: "Lectern ", count: 500).utf8)
        let deflated = try (raw as NSData).compressed(using: .zlib) as Data
        // NSData's .zlib is raw DEFLATE; add a zlib header (78 9C) and a dummy Adler-32.
        let wrapped = [0x78, 0x9C] + [UInt8](deflated) + [0, 0, 0, 0]
        #expect(try StreamDecoder.inflate(wrapped) == [UInt8](raw))
    }

    @Test func pngPredictorAllFilters() throws {
        // Two columns, one byte each: rows encoded with None, Sub, Up, Average, Paeth.
        let rows: [[UInt8]] = [[10, 20], [5, 7], [1, 1], [3, 4], [2, 2]]
        var decodedExpected: [[UInt8]] = []
        var prev: [UInt8] = [0, 0]
        var encoded: [UInt8] = []
        for (filter, row) in rows.enumerated() {
            encoded.append(UInt8(filter))
            encoded += row
            var out = row
            for x in 0..<2 {
                let left = x > 0 ? Int(out[x - 1]) : 0, up = Int(prev[x]), ul = x > 0 ? Int(prev[x - 1]) : 0
                let add: Int = switch filter {
                case 1: left
                case 2: up
                case 3: (left + up) / 2
                case 4: { let p = left + up - ul; let pa = abs(p - left), pb = abs(p - up), pc = abs(p - ul)
                          return pa <= pb && pa <= pc ? left : (pb <= pc ? up : ul) }()
                default: 0
                }
                out[x] = UInt8(truncatingIfNeeded: Int(out[x]) + add)
            }
            decodedExpected.append(out)
            prev = out
        }
        let parms: PDFDictionary = ["Predictor": .integer(12), "Columns": .integer(2)]
        #expect(try StreamDecoder.unpredict(encoded, parms: parms) == decodedExpected.flatMap { $0 })
    }
}

/// Small hand-built files for the writer's error paths.
@Suite struct WriterUnitTests {
    static func minimalPDF(trailerExtra: String = "", corruptOffset: Bool = false) -> Data {
        var out = "%PDF-1.4\n"
        var offsets: [Int] = []
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>",
        ]
        for (i, body) in objects.enumerated() {
            offsets.append(out.utf8.count)
            out += "\(i + 1) 0 obj\n\(body)\nendobj\n"
        }
        let xref = out.utf8.count
        out += "xref\n0 4\n0000000000 65535 f\r\n"
        for (i, o) in offsets.enumerated() {
            out += String(format: "%010d 00000 n\r\n", corruptOffset && i == 2 ? o - 5 : o)
        }
        out += "trailer\n<< /Size 4 /Root 1 0 R \(trailerExtra)>>\nstartxref\n\(xref)\n%%EOF"  // no final EOL
        return Data(out.utf8)
    }

    @Test func addsHighlightToMinimalFile() throws {
        let original = Self.minimalPDF()
        let quad = Quad(rect: PDFRect(x: 20, y: 20, width: 100, height: 14))
        let result = try IncrementalWriter().saveInPlace(original: original, changes: [
            .addMarkup(NewMarkup(kind: .highlight, pageIndex: 0, quads: [quad], contents: "hi", author: "Me")),
        ])
        #expect(result.data.prefix(original.count) == original)
        #expect(result.xrefKind == .table)
        // The original lacks a final EOL, so the update starts with one.
        #expect(result.data[original.count] == 0x0A)
        let reread = try PDFSaveDocument(data: result.data)
        let annots = try reread.annotations(onPage: 0)
        #expect(annots.map(\.subtype) == ["Highlight"])
        #expect(annots.first?.contents == "hi")
        #expect(annots.first?.author == "Me")
        // Page had no /Annots: the page object itself is rewritten (same number and generation).
        #expect(result.rewrittenObjects == [ObjectRef(3, 0)])
    }

    @Test func rewrittenObjectKeepsItsGeneration() throws {
        // Page object 3 is generation 1, as after an earlier tool freed and reused the number.
        var out = "%PDF-1.4\n"
        var offsets: [Int] = []
        let objects = [
            ("1 0", "<< /Type /Catalog /Pages 2 0 R >>"),
            ("2 0", "<< /Type /Pages /Kids [3 1 R] /Count 1 >>"),
            ("3 1", "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>"),
        ]
        for (id, body) in objects {
            offsets.append(out.utf8.count)
            out += "\(id) obj\n\(body)\nendobj\n"
        }
        let xref = out.utf8.count
        out += "xref\n0 4\n0000000000 65535 f\r\n"
        out += String(format: "%010d 00000 n\r\n%010d 00000 n\r\n%010d 00001 n\r\n", offsets[0], offsets[1], offsets[2])
        out += "trailer\n<< /Size 4 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        let result = try IncrementalWriter().saveInPlace(original: Data(out.utf8), changes: [
            .addNote(NewNote(pageIndex: 0, origin: PDFPoint(x: 10, y: 10), contents: "gen"))
        ])
        #expect(result.rewrittenObjects == [ObjectRef(3, 1)])
        let tail = String(decoding: result.data.suffix(from: out.utf8.count), as: UTF8.self)
        #expect(tail.contains("3 1 obj"))
        #expect(tail.contains(" 00001 n\r\n"))
        // No /ID in the original: the writer creates both halves.
        #expect(try PDFSaveDocument(data: result.data).trailer["ID"]?.arrayValue?.count == 2)
    }

    @Test func refusesEncrypted() {
        let data = Self.minimalPDF(trailerExtra: "/Encrypt << /Filter /Standard /V 5 /R 6 >> ")
        #expect(throws: PDFSaveError.encrypted(.malformed("/P is missing or out of range"))) {
            try IncrementalWriter().saveInPlace(original: data, changes: [])
        }
    }

    @Test func refusesStaleXRef() {
        let data = Self.minimalPDF(corruptOffset: true)
        // Object 3's entry points 5 bytes early, into the previous object's "endobj".
        #expect(throws: PDFSaveError.malformed("expected integer at offset 114")) {
            try IncrementalWriter().saveInPlace(original: data, changes: [
                .addNote(NewNote(pageIndex: 0, origin: PDFPoint(x: 10, y: 10), contents: "x")),
            ])
        }
    }

    @Test func unknownAnnotationAndPage() {
        let data = Self.minimalPDF()
        #expect(throws: PDFSaveError.annotationNotFound(ObjectRef(99, 0))) {
            try IncrementalWriter().saveInPlace(original: data, changes: [.delete(ObjectRef(99, 0))])
        }
        #expect(throws: PDFSaveError.pageOutOfRange(3)) {
            try IncrementalWriter().saveInPlace(original: data, changes: [
                .addNote(NewNote(pageIndex: 3, origin: PDFPoint(x: 0, y: 0), contents: "x")),
            ])
        }
    }
}

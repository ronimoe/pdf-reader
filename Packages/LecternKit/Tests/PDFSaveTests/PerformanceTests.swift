import Foundation
import Testing
@testable import PDFSave

/// Saving one highlight to a 1,000-page file must take under a second, including the writer's own
/// post-write verification. Measured in the build `swift test` uses (debug).
@Suite struct PerformanceTests {
    /// 1,000 pages, each with its own text content stream, under a two-level page tree.
    /// `objectStreams` puts the pages and tree into object streams behind a cross-reference stream.
    static func thousandPages(objectStreams: Bool) -> Data {
        let pages = 1000, perNode = 50
        var pdf = TestPDF()
        let nodes = pages / perNode
        // 1 catalog, 2 root, 3…22 intermediate nodes, then page i = 23 + i, content i = 1023 + i.
        let firstPage = 3 + nodes, firstContent = firstPage + pages
        pdf.obj(1, "<< /Type /Catalog /Pages 2 0 R >>")
        var compressed: [(Int, String)] = []
        func add(_ n: Int, _ body: String) { if objectStreams { compressed.append((n, body)) } else { pdf.obj(n, body) } }
        add(2, "<< /Type /Pages /Kids [\((0..<nodes).map { "\(3 + $0) 0 R" }.joined(separator: " "))] /Count \(pages) >>")
        for node in 0..<nodes {
            let kids = (0..<perNode).map { "\(firstPage + node * perNode + $0) 0 R" }.joined(separator: " ")
            add(3 + node, "<< /Type /Pages /Parent 2 0 R /Kids [\(kids)] /Count \(perNode) >>")
        }
        for i in 0..<pages {
            add(firstPage + i, "<< /Type /Page /Parent \(3 + i / perNode) 0 R /MediaBox [0 0 612 792] "
                + "/Resources << /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >> "
                + "/Contents \(firstContent + i) 0 R >>")
        }
        for i in 0..<pages {
            let text = "BT /F1 12 Tf 72 720 Td (Page \(i + 1) of the performance file. Lectern test corpus.) Tj ET"
            pdf.stream(firstContent + i, dict: "", data: Array(text.utf8))
        }
        if objectStreams {
            // Object streams of 100 objects each, numbered after the content streams.
            var number = firstContent + pages
            for chunk in stride(from: 0, to: compressed.count, by: 100) {
                pdf.objStm(number, Array(compressed[chunk..<min(chunk + 100, compressed.count)]))
                number += 1
            }
            return pdf.finishStream(number: number, trailer: "/Root 1 0 R")
        }
        return pdf.finishTable(trailer: "/Size \(firstContent + pages) /Root 1 0 R")
    }

    static func measure(_ data: Data) throws -> (seconds: Double, result: SaveResult) {
        let change = AnnotationChange.addMarkup(NewMarkup(
            kind: .highlight, pageIndex: 637, quads: [Quad(rect: PDFRect(x: 72, y: 716, width: 200, height: 14))], contents: "fast"))
        var result: SaveResult?
        let clock = ContinuousClock()
        let elapsed = try clock.measure { result = try IncrementalWriter().saveInPlace(original: data, changes: [change]) }
        let c = elapsed.components
        return (Double(c.seconds) + Double(c.attoseconds) / 1e18, result!)
    }

    @Test(arguments: [false, true]) func oneHighlightOnAThousandPagesUnderOneSecond(_ objectStreams: Bool) throws {
        let data = Self.thousandPages(objectStreams: objectStreams)
        let doc = try PDFSaveDocument(data: data)
        #expect(doc.pageCount == 1000)
        _ = try Self.measure(data)  // warm-up
        let runs = try (0..<3).map { _ in try Self.measure(data) }
        let best = runs.map(\.seconds).min()!
        print(String(format: "perf: 1 highlight on 1,000 pages (%@, %d KB): best %.3f s, runs %@", objectStreams ? "xref stream + object streams" : "classic table",
                     data.count / 1024, best, runs.map { String(format: "%.3f", $0.seconds) }.joined(separator: " ")))
        #expect(runs.allSatisfy { $0.seconds < 1.0 }, "runs: \(runs.map(\.seconds))")
        let result = runs[0].result
        #expect(result.data.prefix(data.count) == data)
        #expect(try PDFSaveDocument(data: result.data).annotations(onPage: 637).map(\.subtype) == ["Highlight"])

        let clock = ContinuousClock()
        let evaluate = clock.measure { #expect(Saveability.evaluate(data) == .inPlace) }
        print("perf: Saveability.evaluate on the same file: \(evaluate)")
    }
}

import AppKit
import PDFKit
import Testing
@testable import Lectern

@Suite struct ReaderDocumentTests {
    @Test func readsPDFAndKeepsOriginalBytes() throws {
        let data = try #require(TestPDF.make(pageCount: 3))
        let document = ReaderDocument()
        try document.read(from: data, ofType: "com.adobe.pdf")
        #expect(document.originalData == data)
        #expect(document.pdfDocument?.pageCount == 3)
    }

    @Test func rejectsNonPDF() {
        let document = ReaderDocument()
        #expect(throws: (any Error).self) {
            try document.read(from: Data("not a pdf".utf8), ofType: "com.adobe.pdf")
        }
    }

    @Test func neverAutosaves() {
        #expect(ReaderDocument.autosavesInPlace == false)
        #expect(ReaderDocument.preservesVersions == false)
    }
}

/// Builds small PDFs in memory for tests.
enum TestPDF {
    static func make(pageCount: Int) -> Data? {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        for index in 0..<pageCount {
            context.beginPDFPage(nil)
            let text = "Page \(index + 1)" as NSString
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            text.draw(at: CGPoint(x: 72, y: 700), withAttributes: [.font: NSFont.systemFont(ofSize: 24)])
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
}

import AppKit
import PDFKit
import Persistence
import ReaderCore
import Testing
@testable import Lectern

/// Main-thread cost of opening a long document beyond PDFKit's own work
/// (spec §9.1: large documents must not make the interface unresponsive).
///
/// Opening a window costs the same whatever the document (the window,
/// toolbar, split view and sidebar), so it is measured on a one-page file
/// and taken out: what remains is what this app adds for a long document,
/// and it must stay under 50 ms on a 2,000-page file.
@MainActor
@Suite(.serialized, .noUI) struct OpeningPerformanceTests {
    private struct Timing {
        var pdfKit: TimeInterval
        var open: TimeInterval
        var overhead: TimeInterval { open - pdfKit }
    }

    private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Best of three of: PDFKit alone (read, parse, a PDFView laying the
    /// document out), and the app opening the same file into a window.
    private func measure(pages: Int, folder: TemporaryFolder) throws -> Timing {
        let data = FixturePDF.make(pageTexts: (0..<pages).map { "Page \($0 + 1) of a long manual" }, id: String(format: "%04X", pages))
        let url = try folder.write(data, to: "long-\(pages).pdf")
        var timing = Timing(pdfKit: .infinity, open: .infinity)
        for _ in 0..<3 {
            let start = now()
            let document = try #require(PDFDocument(data: try Data(contentsOf: url)))
            let view = PDFView(frame: NSRect(x: 0, y: 0, width: 900, height: 1000))
            view.document = document
            view.layoutDocumentView()
            timing.pdfKit = min(timing.pdfKit, now() - start)
        }
        for _ in 0..<3 {
            let store = folder.store()
            let start = now()
            let document = try ReaderDocument.opened(url)
            let controller = ReaderWindowController(document: document, passwordStore: InMemoryPasswordStore(), presenter: RecordingPresenter(), stateStore: store)
            document.addWindowController(controller)
            controller.splitViewController.view.layoutSubtreeIfNeeded()
            timing.open = min(timing.open, now() - start)
            #expect(controller.isShowingContent)
            document.close()
        }
        return timing
    }

    @Test func openingALongDocumentAddsLittleToPDFKitsOwnWork() throws {
        let folder = try TemporaryFolder()
        let long = try measure(pages: 2000, folder: folder)
        let short = try measure(pages: 1, folder: folder)
        let perDocument = long.overhead - short.overhead
        NSLog(
            "M2 open, 2000 pages: open %.1f ms, PDFKit %.1f ms, overhead %.1f ms; window alone %.1f ms; page-dependent overhead %.1f ms",
            long.open * 1000, long.pdfKit * 1000, long.overhead * 1000, short.overhead * 1000, perDocument * 1000
        )
        #expect(perDocument < 0.05, "2,000 pages add \(Int(perDocument * 1000)) ms beyond PDFKit and the window itself")
        // A loose guard on the whole, so window setup doesn't creep up.
        #expect(long.overhead < 0.15, "opening took \(Int(long.open * 1000)) ms, PDFKit alone \(Int(long.pdfKit * 1000)) ms")
    }
}

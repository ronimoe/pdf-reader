import AppKit
import PDFKit
import Testing
@testable import Lectern
@testable import ReaderKit

/// PDFKit calls into its view from background queues (form detection, page
/// analysis). These guard the crash seen in the field and the analysis switch.
@Suite struct PDFKitBackgroundQueueTests {
    @Test func documentCanBeReadOffTheMainThread() throws {
        let data = try #require(TestPDF.make(pageCount: 2))
        let view = ReaderPDFView(frame: NSRect(x: 0, y: 0, width: 400, height: 500))
        view.show(PDFDocument(data: data))
        nonisolated(unsafe) let unsafeView = view
        let pageCount = DispatchQueue.global().sync {
            (unsafeView.value(forKey: "document") as? PDFDocument)?.pageCount
        }
        #expect(pageCount == 2)
    }

    @Test func automaticAnalysisIsSwitchedOff() {
        let view = ReaderPDFView(frame: .zero)
        for key in ReaderPDFView.automaticAnalysisKeys {
            let setter = NSSelectorFromString("set" + key.prefix(1).uppercased() + key.dropFirst() + ":")
            guard view.responds(to: setter) else { continue }
            #expect(view.value(forKey: key) as? Bool == false, "\(key) is still on")
        }
    }

    @Test func thisPDFKitHasTheAnalysisSwitches() {
        // If Apple renames these, the switch above silently does nothing; fail
        // loudly so the next PDFKit version gets looked at.
        let view = PDFView(frame: .zero)
        #expect(view.responds(to: NSSelectorFromString("setFormDetectionEnabled:")))
        #expect(view.responds(to: NSSelectorFromString("setDocumentAnalysisEnabled:")))
    }

    @Test func documentChangeStillResetsTheView() throws {
        let data = try #require(TestPDF.make(pageCount: 3))
        let view = ReaderPDFView(frame: NSRect(x: 0, y: 0, width: 400, height: 500))
        view.show(PDFDocument(data: data))
        #expect(view.document?.pageCount == 3)
        view.show(PDFDocument(data: try #require(TestPDF.make(pageCount: 1))))
        #expect(view.document?.pageCount == 1)
    }
}

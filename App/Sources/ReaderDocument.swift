import AppKit
import PDFKit

/// One open PDF. Holds the bytes exactly as loaded (the incremental writer
/// appends to these, decision A1/B7) and the PDFKit model built from them.
final class ReaderDocument: NSDocument {
    private(set) var originalData = Data()
    private(set) var pdfDocument: PDFDocument?

    // A1: nothing is ever written without an explicit Save.
    override nonisolated class var autosavesInPlace: Bool { false }
    override nonisolated class var autosavesDrafts: Bool { false }
    override nonisolated class var preservesVersions: Bool { false }

    override nonisolated func read(from data: Data, ofType typeName: String) throws {
        guard PDFDocument(data: data) != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        MainActor.assumeIsolated {
            self.originalData = data
            self.pdfDocument = PDFDocument(data: data)
        }
    }

    override func makeWindowControllers() {
        addWindowController(ReaderWindowController(document: self))
    }
}

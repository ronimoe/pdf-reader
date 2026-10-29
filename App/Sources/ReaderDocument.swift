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

    // Saving lands with the incremental writer in M4. Until then no type is
    // writable, so Save stays disabled instead of hitting NSDocument's
    // default data(ofType:), which raises.
    override nonisolated class var writableTypes: [String] { [] }

    // read(from:ofType:) assumes the main actor; keep NSDocument from
    // calling it on a background thread.
    override nonisolated class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { false }

    override nonisolated func read(from data: Data, ofType typeName: String) throws {
        guard let pdf = PDFDocument(data: data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        nonisolated(unsafe) let parsed = pdf
        MainActor.assumeIsolated {
            self.originalData = data
            self.pdfDocument = parsed
        }
    }

    override func makeWindowControllers() {
        addWindowController(ReaderWindowController(document: self))
    }
}

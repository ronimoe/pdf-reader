import AppKit
import PDFKit
import PDFSave
import Persistence
import ReaderCore
import ReaderKit
import Testing
@testable import Lectern

/// Parent suite for M4b (annotations and saving). Serialized: the tests share the app's event
/// queue, open real windows and write real files.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(10)), .noUI)
struct M4Tests {}

/// Files from `Tests/Corpus/public`, bundled with the tests (the test host is sandboxed).
nonisolated enum Corpus {
    static func data(_ name: String) throws -> Data {
        let bundle = Bundle(for: CorpusBundleMarker.self)
        let url = try #require(bundle.url(forResource: name, withExtension: "pdf"), "\(name).pdf isn't bundled")
        return try Data(contentsOf: url)
    }
}

private final class CorpusBundleMarker {}

/// Runs a tool the test script requires (qpdf). The test host is sandboxed but may run Homebrew
/// tools on files in its own container.
nonisolated enum ExternalTool {
    static let qpdfPaths = ["/opt/homebrew/bin/qpdf", "/usr/local/bin/qpdf"]

    /// `qpdf --check`: the exit status and output. An encrypted file is opened with `password`.
    static func qpdfCheck(_ url: URL, password: String? = nil) throws -> (status: Int32, output: String) {
        let path = try #require(qpdfPaths.first { FileManager.default.isExecutableFile(atPath: $0) }, "qpdf is required (brew install qpdf)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = (password.map { ["--password=\($0)"] } ?? []) + ["--check", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }
}

/// A real document opened from a file in a temporary folder, in an invisible reader window, with
/// its own state store and crash journal, and every prompt recorded instead of shown.
@MainActor
final class AnnotationHarness {
    let folder: TemporaryFolder
    let fileURL: URL
    let store: DocumentStateStore
    let journal: AnnotationJournal
    let document: ReaderDocument
    let controller: ReaderWindowController
    let presenter = RecordingPresenter()
    let preferences = ReaderPreferences.ephemeral()
    private(set) var openedCopies: [URL] = []
    /// UI the tripwire had blocked before this harness opened.
    private let blockedUIBefore = UITripwire.shared.calls.count

    /// Copies `name` from the corpus (or writes `data`) into a fresh folder and opens it.
    convenience init(corpus name: String, password: String? = nil) async throws {
        let folder = try TemporaryFolder()
        let url = try folder.write(try Corpus.data(name), to: "\(name).pdf")
        try await self.init(file: url, folder: folder, password: password)
    }

    convenience init(data: Data, name: String = "document.pdf") async throws {
        let folder = try TemporaryFolder()
        let url = try folder.write(data, to: name)
        try await self.init(file: url, folder: folder)
    }

    /// Opens `file` again, sharing the store and journal of an earlier harness (a relaunch).
    init(
        file: URL, folder: TemporaryFolder, store: DocumentStateStore? = nil, journal: AnnotationJournal? = nil, password: String? = nil,
        journalChoice: JournalChoice = .restore, staleJournalChoice: JournalChoice = .discard, defersJournalOffer: Bool = false,
        inspectionDelay: Duration = .zero
    ) async throws {
        self.folder = folder
        fileURL = file
        self.store = store ?? folder.store()
        self.journal = journal ?? AnnotationJournal(directory: folder.url.appending(path: "Journal", directoryHint: .isDirectory), debounce: .seconds(60))
        document = try ReaderDocument.opened(file)
        document.undoManager?.groupsByEvent = false
        document.inspectionDelay = inspectionDelay
        controller = ReaderWindowController(
            document: document, passwordStore: InMemoryPasswordStore(), presenter: presenter, stateStore: self.store,
            previewPresenter: TestPreviewPresenter(), urlOpener: RecordingURLOpener(), preferences: preferences, journal: self.journal
        )
        presenter.journalChoice = journalChoice
        presenter.defersJournalOffer = defersJournalOffer
        presenter.staleJournalChoice = staleJournalChoice
        controller.openCopy = { [weak self] url in self?.openedCopies.append(url) }
        document.addWindowController(controller)
        let window = try #require(controller.window)
        window.setFrameAutosaveName("")
        window.setContentSize(NSSize(width: 700, height: 900))
        window.setFrameOrigin(NSScreen.screens.first?.frame.origin ?? .zero)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        controller.splitViewController.view.layoutSubtreeIfNeeded()
        if let password { _ = controller.submitPassword(password, remember: false, purpose: .open) }
        if inspectionDelay == .zero { await waitForInspection() }
        Spin.runLoop(0.05)
    }

    func waitForInspection() async {
        await document.inspection?.value
    }

    var editor: AnnotationEditor { document.annotations! }
    var pdf: PDFDocument { document.pdfDocument! }
    var view: ReaderPDFView { controller.primaryPane.view }
    var window: NSWindow { controller.window! }
    var undo: UndoManager { document.undoManager! }

    /// The first match of `text` on `page`.
    func selection(_ text: String, page: Int = 0) throws -> PDFSelection {
        let matches = pdf.findString(text, withOptions: [])
        return try #require(matches.first { $0.pages.first.map(pdf.index(for:)) == page }, "“\(text)” not on page \(page + 1)")
    }

    /// Selects `text` in the view, as a drag would.
    func select(_ text: String, page: Int = 0) throws {
        view.setCurrentSelection(try selection(text, page: page), animate: false)
    }

    @discardableResult
    func highlight(_ text: String, page: Int = 0, kind: MarkupKind = .highlight) throws -> PDFAnnotation {
        let created = try editor.addMarkup(kind, covering: try selection(text, page: page), color: .yellow)
        return try #require(created.first)
    }

    /// Saves through NSDocument's save path (safe save to a temporary file, then the swap).
    func save(to url: URL? = nil, _ operation: NSDocument.SaveOperationType = .saveOperation) async throws {
        let target = url ?? fileURL
        let error: (any Error)? = await withCheckedContinuation { continuation in
            document.save(to: target, ofType: "com.adobe.pdf", for: operation) { error in
                continuation.resume(returning: error)
            }
        }
        if let error { throw error }
    }

    var fileBytes: Data { (try? Data(contentsOf: fileURL)) ?? Data() }

    func close() {
        controller.window?.orderOut(nil)
        document.close()
        let blocked = UITripwire.shared.calls.dropFirst(blockedUIBefore)
        #expect(blocked.isEmpty, "a test tried to show UI: \(Array(blocked))")
    }

    /// Leaves without closing the document, as a crash would: nothing is cleaned up.
    func abandon() {
        controller.window?.orderOut(nil)
    }

    /// Spins the run loop until `condition` holds or the time is up.
    func wait(until condition: () -> Bool, timeout: TimeInterval = 5) {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { Spin.runLoop(0.02) }
    }

    /// Waits for work the app started in its own tasks: suspends, so main-actor tasks can run.
    func settle(until condition: () -> Bool, timeout: TimeInterval = 5) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end {
            try? await Task.sleep(for: .milliseconds(20))
            Spin.runLoop(0.01)
        }
    }
}

/// Reads a saved file back: its annotations as PDFKit sees them, and as PDFSave parses them.
@MainActor
struct SavedFile {
    let data: Data
    let pdf: PDFDocument
    let descriptors: [AnnotationDescriptor]

    /// An encrypted file is unlocked in PDFKit and decrypted by PDFSave with `password`.
    init(_ data: Data, password: String? = nil) throws {
        self.data = data
        pdf = try #require(PDFDocument(data: data))
        if pdf.isLocked { try #require(pdf.unlock(withPassword: password ?? ""), "PDFKit doesn't unlock the saved file") }
        descriptors = try PDFSaveDocument(data: data, password: password).annotations()
    }

    /// PDFKit's annotations named `name` (our `/NM`).
    func annotations(named name: String) -> [PDFAnnotation] {
        (0..<pdf.pageCount).flatMap { pdf.page(at: $0)?.annotations ?? [] }.filter { ($0.value(forAnnotationKey: .name) as? String) == name }
    }

    var lecternDescriptors: [AnnotationDescriptor] { descriptors.filter(\.isLectern) }
}

extension AnnotationChange {
    var name: String? { addedName }
}

/// Text of the appended update, for searching keys.
func appendedText(_ data: Data, after original: Data) -> String {
    String(decoding: data.suffix(from: original.count), as: UTF8.self)
}

/// Two identical highlights over the same words (same /Rect, no /Contents), plus a third that
/// differs: the matcher can't tell the twins apart.
nonisolated enum TwinFixture {
    static func make() -> Data {
        var objects: [Int: String] = [:]
        objects[1] = "<< /Type /Catalog /Pages 2 0 R >>"
        objects[2] = "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"
        objects[3] = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> /Annots [6 0 R 7 0 R 8 0 R] >>"
        objects[4] = SpikeRawPDF.stream("BT /F1 14 Tf 72 700 Td (Twin highlights cover these words) Tj ET\nBT /F1 14 Tf 72 600 Td (A single highlight covers this line) Tj ET\n")
        objects[5] = SpikeRawPDF.helvetica
        let quad = "/QuadPoints [72 716 340 716 72 696 340 696]"
        objects[6] = "<< /Type /Annot /Subtype /Highlight /Rect [72 696 340 716] \(quad) /C [1 1 0] >>"
        objects[7] = "<< /Type /Annot /Subtype /Highlight /Rect [72 696 340 716] \(quad) /C [1 1 0] >>"
        objects[8] = "<< /Type /Annot /Subtype /Highlight /Rect [72 596 340 616] /QuadPoints [72 616 340 616 72 596 340 596] /C [0 1 0] /Contents (single) >>"
        return SpikeRawPDF.build(objects: objects, root: 1).data
    }
}

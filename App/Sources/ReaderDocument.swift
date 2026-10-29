import AppKit
import PDFKit
import ReaderCore

/// One open PDF. Holds the bytes exactly as loaded (the incremental writer
/// appends to these, decision A1/B7) and the PDFKit model built from them.
final class ReaderDocument: NSDocument {
    private(set) var originalData = Data()
    private(set) var pdfDocument: PDFDocument?

    /// Each page's `/Rotate` as loaded, before any view rotation (B9). The
    /// save path uses these to write pages back unrotated (architecture §4.3).
    /// Empty until the document is unlocked.
    private(set) var originalPageRotations: [Int] = []
    /// The catalog's layout hints (B1). Read once the document is unlocked.
    private(set) var layoutHints = DocumentLayoutHints.none
    /// The pages' labels, for go to page and the sidebar. Read once the
    /// document is unlocked.
    /// Built the first time it's needed (go to page, search results): reading
    /// every page's label creates every `PDFPage`, which costs tens of
    /// milliseconds on a long document.
    var pageNumbering: PageNumbering {
        if let cachedNumbering { return cachedNumbering }
        guard let pdfDocument, !pdfDocument.isLocked else { return PageNumbering(pageCount: 0) }
        let numbering = definesPageLabels
            ? PageNumbering(labels: (0..<pdfDocument.pageCount).map { pdfDocument.page(at: $0)?.label ?? "" }, definesLabels: true)
            : PageNumbering(pageCount: pdfDocument.pageCount)
        cachedNumbering = numbering
        return numbering
    }
    private var cachedNumbering: PageNumbering?
    /// Whether the catalog has `/PageLabels`. Read once the document is unlocked.
    private(set) var definesPageLabels = false

    /// One page's label, without building every label: the page's own when
    /// the document defines labels, its number otherwise.
    func label(forPageAt index: Int) -> String {
        if let cachedNumbering { return cachedNumbering.label(forPageAt: index) }
        guard definesPageLabels, let label = pdfDocument?.page(at: index)?.label, !label.isEmpty else { return String(index + 1) }
        return label
    }
    /// Identifies the document in the Keychain; readable while locked.
    var documentKey: DocumentKey {
        if let cachedKey { return cachedKey }
        let key = DocumentKey(pdfData: originalData)
        cachedKey = key
        return key
    }
    private var cachedKey: DocumentKey?
    /// The password that last gained access, kept in memory only, so the
    /// background renderers and a reload can open their own copies (B6).
    /// Never stored.
    private(set) var sessionPassword: String?
    /// True once the file has been deleted or moved to the Trash (B7).
    private(set) var fileWasRemoved = false

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
            self.documentDidBecomeReadableIfUnlocked()
        }
    }

    override func makeWindowControllers() {
        addWindowController(ReaderWindowController(document: self))
    }

    var readerWindowController: ReaderWindowController? {
        windowControllers.lazy.compactMap { $0 as? ReaderWindowController }.first
    }

    // MARK: Passwords and permissions (B6)

    var isPasswordLocked: Bool { pdfDocument?.isLocked ?? true }

    /// True once the owner password has been given, or for unencrypted files.
    var hasOwnerAccess: Bool { pdfDocument?.permissionsStatus == .owner }

    /// PDFKit lifts these restrictions once the owner password is given.
    var allowsCopying: Bool { !isPasswordLocked && (pdfDocument?.allowsCopying ?? false) }
    var allowsPrinting: Bool { !isPasswordLocked && (pdfDocument?.allowsPrinting ?? false) }

    /// Tries a user or owner password and returns whether it gained access:
    /// a locked document opened, or an open one gained owner access. PDFKit's
    /// own `unlock` returns true for any string once a document is open, so
    /// its result alone can't tell a wrong owner password from a right one.
    @discardableResult
    func unlock(withPassword password: String) -> Bool {
        guard let pdfDocument else { return false }
        let wasLocked = pdfDocument.isLocked
        guard pdfDocument.unlock(withPassword: password) else { return false }
        documentDidBecomeReadableIfUnlocked()
        let gained = wasLocked ? !pdfDocument.isLocked : hasOwnerAccess
        if gained { sessionPassword = password }
        return gained
    }

    private var hasRecordedOriginals = false

    /// Records the original rotations and reads the hints, once, as soon as
    /// the pages and catalog are readable.
    private func documentDidBecomeReadableIfUnlocked() {
        guard let pdfDocument, !pdfDocument.isLocked, !hasRecordedOriginals else { return }
        hasRecordedOriginals = true
        appliedViewRotation = 0
        cachedNumbering = nil
        if let reference = pdfDocument.documentRef {
            // Read from CoreGraphics' page dictionaries: asking PDFKit would
            // create a PDFPage for every page (about 90 ms for 2,000 pages).
            originalPageRotations = (0..<reference.numberOfPages).map { Int(reference.page(at: $0 + 1)?.rotationAngle ?? 0) }
            layoutHints = DocumentLayoutHints(document: reference)
            definesPageLabels = PageNumbering.definesPageLabels(reference)
        } else {
            originalPageRotations = (0..<pdfDocument.pageCount).map { pdfDocument.page(at: $0)?.rotation ?? 0 }
            definesPageLabels = false
        }
    }

    // MARK: Changes on disk (B7)

    /// How long to wait for a writer to finish before reading the file.
    var reloadDelay: TimeInterval = 0.3
    private var pendingReload: DispatchWorkItem?

    // NSDocument is the file presenter for its file. These arrive on its
    // presenter queue; the work happens on the main thread.

    override nonisolated func presentedItemDidChange() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.scheduleReload() }
        }
    }

    override nonisolated func presentedItemDidMove(to newURL: URL) {
        super.presentedItemDidMove(to: newURL)
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.fileDidMove(to: newURL) }
        }
    }

    override nonisolated func accommodatePresentedItemDeletion(completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
        // The document stays open on the bytes it already has.
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.fileDidGoAway() }
        }
        completionHandler(nil)
    }

    /// Writers often touch a file several times; read it once they settle.
    func scheduleReload() {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { _ = self?.reloadFromDiskIfChanged() }
        }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + reloadDelay, execute: work)
    }

    /// Reads the file through file coordination and, if its bytes changed
    /// and they parse, reloads silently (B7, no unsaved annotations until
    /// M4). Returns whether it reloaded.
    @discardableResult
    func reloadFromDiskIfChanged() -> Bool {
        pendingReload?.cancel()
        pendingReload = nil
        guard let url = fileURL else { return false }
        var data: Data?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: self).coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { url in
            data = try? Data(contentsOf: url)
        }
        guard let data else {
            if !FileManager.default.fileExists(atPath: url.path) { fileDidGoAway() }
            return false
        }
        guard data != originalData else { return false }
        // A file caught half-written doesn't parse; the next change notice
        // brings the finished one.
        guard let pdf = PDFDocument(data: data) else { return false }
        reload(with: data, pdf: pdf)
        return true
    }

    /// Replaces the bytes and the model with the file's new contents.
    func reload(with data: Data, pdf: PDFDocument) {
        originalData = data
        pdfDocument = pdf
        cachedKey = nil
        hasRecordedOriginals = false
        originalPageRotations = []
        layoutHints = .none
        cachedNumbering = nil
        definesPageLabels = false
        if let sessionPassword, pdf.isEncrypted {
            pdf.unlock(withPassword: sessionPassword)
        }
        documentDidBecomeReadableIfUnlocked()
        fileModificationDate = (try? fileURL?.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        readerWindowController?.documentDidReload()
    }

    private func fileDidMove(to url: URL) {
        if Self.isInTrash(url) {
            fileDidGoAway()
        } else {
            readerWindowController?.documentDidMove(to: url)
        }
    }

    /// Whether `url` is inside a Trash: the home folder's, or the per-volume
    /// `.Trashes` on another disk.
    nonisolated static func isInTrash(_ url: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        if components.contains(".Trash") || components.contains(".Trashes") { return true }
        guard let trash = try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: url, create: false) else {
            return false
        }
        let trashPath = trash.standardizedFileURL.resolvingSymlinksInPath().path
        return url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(trashPath + "/")
    }

    /// Deleted, or moved to the Trash: the document stays open with a
    /// notice. Save a Copy arrives in M4.
    func fileDidGoAway() {
        guard !fileWasRemoved else { return }
        fileWasRemoved = true
        readerWindowController?.showFileRemovedNotice()
    }

    // MARK: View rotation (B9)

    /// The page's `/Rotate` as loaded, or nil for an index out of range or a
    /// document that is still locked.
    func originalRotation(ofPageAt index: Int) -> Int? {
        originalPageRotations.indices.contains(index) ? originalPageRotations[index] : nil
    }

    /// Rotates every page by `degrees` on top of its original rotation. Only
    /// the in-memory model changes; `originalData` is never touched.
    func applyViewRotation(_ degrees: Int) {
        let degrees = ViewSettings.normalized(degrees)
        // Pages already show their own rotation; touching them would create
        // every PDFPage for nothing.
        guard let pdfDocument, degrees != appliedViewRotation else { return }
        for (index, original) in originalPageRotations.enumerated() {
            pdfDocument.page(at: index)?.rotation = ViewSettings.normalized(original + degrees)
        }
        appliedViewRotation = degrees
    }

    /// The view rotation the model's pages carry now.
    private var appliedViewRotation = 0

    // MARK: Printing

    override func printDocument(_ sender: Any?) {
        guard allowsPrinting else {
            if !isPasswordLocked { readerWindowController?.explainBlocked(.print) }
            return
        }
        super.printDocument(sender)
    }

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        guard let pdfDocument, allowsPrinting else {
            throw CocoaError(.featureUnsupported, userInfo: [
                NSLocalizedDescriptionKey: BlockedAction.print.title,
                NSLocalizedRecoverySuggestionErrorKey: BlockedAction.print.message,
            ])
        }
        let info = printInfo.copy() as? NSPrintInfo ?? NSPrintInfo()
        for (key, value) in printSettings {
            info.dictionary()[key] = value
        }
        guard let operation = pdfDocument.printOperation(for: info, scalingMode: .pageScaleToFit, autoRotate: true) else {
            throw CocoaError(.featureUnsupported)
        }
        operation.jobTitle = displayName
        return operation
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        // Print stays enabled for restricted documents, so choosing it
        // explains the restriction instead of failing silently.
        if item.action == #selector(printDocument(_:)) {
            return !isPasswordLocked
        }
        return super.validateUserInterfaceItem(item)
    }
}

/// Actions a document's permissions can forbid (B6).
enum BlockedAction: Equatable {
    case copy
    case print

    var title: String {
        switch self {
        case .copy: "This document doesn’t allow copying"
        case .print: "This document doesn’t allow printing"
        }
    }

    var message: String {
        switch self {
        case .copy: "Its author restricted copying text and images. If you have the owner password, you can enter it to remove the restriction."
        case .print: "Its author restricted printing. If you have the owner password, you can enter it to remove the restriction."
        }
    }
}

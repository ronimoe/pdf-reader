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
    /// Identifies the document in the Keychain; readable while locked.
    private(set) lazy var documentKey = DocumentKey(pdfData: originalData)

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

    /// Tries a user or owner password. A wrong password never re-locks a
    /// document that is already open.
    @discardableResult
    func unlock(withPassword password: String) -> Bool {
        guard let pdfDocument, pdfDocument.unlock(withPassword: password) else { return false }
        documentDidBecomeReadableIfUnlocked()
        return true
    }

    private var hasRecordedOriginals = false

    /// Records the original rotations and reads the hints, once, as soon as
    /// the pages and catalog are readable.
    private func documentDidBecomeReadableIfUnlocked() {
        guard let pdfDocument, !pdfDocument.isLocked, !hasRecordedOriginals else { return }
        hasRecordedOriginals = true
        originalPageRotations = (0..<pdfDocument.pageCount).map { pdfDocument.page(at: $0)?.rotation ?? 0 }
        if let reference = pdfDocument.documentRef {
            layoutHints = DocumentLayoutHints(document: reference)
        }
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
        guard let pdfDocument else { return }
        for (index, original) in originalPageRotations.enumerated() {
            pdfDocument.page(at: index)?.rotation = ViewSettings.normalized(original + degrees)
        }
    }

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

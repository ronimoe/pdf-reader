import AppKit
import PDFKit
import PDFSave
import ReaderCore

/// Where ⌘S goes (A1, architecture §3.2).
enum SaveRoute: Equatable {
    /// No unsaved annotations: nothing is written.
    case nothingToSave
    /// `saveInPlace` over the file, through NSDocument's safe save.
    case inPlace
    /// The file must not be changed: explain why in a Save As panel, and save a copy there.
    case copy(explanation: String)
    /// Annotations can't be saved in this document at all.
    case refused(AnnotationRefusal)
    /// The file changed on disk since it was loaded: the B7 choice instead of a save.
    case changedOnDisk
}

/// A save's result, held between `write(to:…)` and the save's completion.
struct WrittenSave {
    let operation: NSDocument.SaveOperationType
    let data: Data
    let descriptors: [AnnotationDescriptor]?
}

extension ReaderDocument {
    // MARK: The annotation model

    func makeAnnotationEditor() {
        guard let pdfDocument else {
            annotations = nil
            return
        }
        let editor = AnnotationEditor(pdf: pdfDocument, original: originalData)
        editor.undoManager = undoManager
        editor.onChange = { [weak self, weak editor] in
            guard let self, let editor, editor === self.annotations else { return }
            self.annotationsDidChange()
        }
        annotations = editor
        readerWindowController?.annotationEditorDidChange()
    }

    var hasUnsavedAnnotations: Bool { annotations?.hasUnsavedChanges ?? false }

    func annotationsDidChange() {
        updateChangeCount(hasUnsavedAnnotations ? .changeDone : .changeCleared)
        for controller in windowControllers { controller.setDocumentEdited(isDocumentEdited) }
        readerWindowController?.annotationsDidChange()
    }

    /// The unsaved-annotation state is the change list itself, never a counter that undo and
    /// redo could drift away from it.
    override var isDocumentEdited: Bool { hasUnsavedAnnotations }

    /// Whether the file's location can be written: a locked file, a read-only volume or a
    /// file without write access makes the document copy-only (A1).
    var isReadOnlyLocation: Bool {
        guard let url = fileURL else { return false }
        let values = try? url.resourceValues(forKeys: [.isWritableKey, .volumeIsReadOnlyKey, .isUserImmutableKey])
        return values?.isWritable == false || values?.volumeIsReadOnly == true || values?.isUserImmutable == true
    }

    /// Works out, off the main thread, whether and how the file can be saved, and what
    /// annotations it holds. Creating and changing annotations waits for it.
    @discardableResult
    func inspectForAnnotations() -> Task<Void, Never>? {
        guard let editor = annotations else { return nil }
        let data = originalData
        let readOnly = isReadOnlyLocation
        let delay = inspectionDelay
        let task = Task { [weak self, weak editor] in
            let info = await AnnotationFileInfo.inspect(data, readOnlyLocation: readOnly)
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard let self, let editor, editor === self.annotations, editor.original == data else { return }
            editor.load(info)
            self.readerWindowController?.annotationInfoDidLoad()
        }
        inspection = task
        return task
    }

    // MARK: Routing ⌘S

    var saveRoute: SaveRoute {
        guard let editor = annotations else { return .nothingToSave }
        // A document that can't hold annotations says so when the user tries to save (B6, Rule 7).
        if case .unsupported(let reason)? = editor.saveability { return .refused(.cannotSave(reason)) }
        if fileWasRemoved {
            return editor.hasUnsavedChanges ? .copy(explanation: "The original file was deleted or moved to the Trash. Choose where to save the document with your annotations.") : .nothingToSave
        }
        guard editor.hasUnsavedChanges else { return .nothingToSave }
        guard let url = fileURL else { return .copy(explanation: "Choose where to save the document with your annotations.") }
        guard let saveability = editor.saveability else { return .refused(.stillChecking) }
        switch saveability {
        case .inPlace:
            if let onDisk = try? Data(contentsOf: url), onDisk != originalData { return .changedOnDisk }
            return .inPlace
        case .copyOnly(let reasons):
            return .copy(explanation: Self.copyExplanation(reasons))
        case .unsupported(let reason):
            return .refused(.cannotSave(reason))
        }
    }

    static func copyExplanation(_ reasons: [CopyOnlyReason]) -> String {
        let why: String = switch reasons.first {
        case .certified?: "This document is certified by its author, and adding annotations can invalidate the certification."
        case .readerExtended?: "This form was prepared for Adobe Reader, and changing it removes the extra features Adobe Reader offers for it."
        case .signed?: "This document is signed, and annotations added to it would be reported as changes made after signing."
        case .readOnlyLocation?: "The file is locked, or in a place Lectern can’t write to."
        case nil: "This file can’t be changed safely."
        }
        return why + " Lectern leaves the original exactly as it is and saves your annotations in a copy."
    }

    override func save(withDelegate delegate: Any?, didSave didSaveSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        switch saveRoute {
        case .inPlace:
            // The bytes are what was loaded (the route checked). A file only touched since, with
            // the same bytes, is the same file: NSDocument mustn't treat it as changed by another
            // app and ask over B7's head.
            if let url = fileURL, let onDisk = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               onDisk != fileModificationDate {
                fileModificationDate = onDisk
            }
            super.save(withDelegate: delegate, didSave: didSaveSelector, contextInfo: contextInfo)
        case .nothingToSave:
            // Nothing changed, so nothing is written; a caller waiting for an answer still gets one.
            answer(delegate, didSave: didSaveSelector, contextInfo: contextInfo, saved: true)
        case .copy(let explanation):
            savePanelMessage = explanation
            runModalSavePanel(for: .saveAsOperation, delegate: delegate, didSave: didSaveSelector, contextInfo: contextInfo)
        case .refused(let refusal):
            readerWindowController?.explainAnnotationRefusal(refusal)
            // Close ▸ Save and Quit ▸ Save wait for this answer; nothing was saved.
            answer(delegate, didSave: didSaveSelector, contextInfo: contextInfo, saved: false)
        case .changedOnDisk:
            readerWindowController?.fileChangedWithUnsavedAnnotations()
            answer(delegate, didSave: didSaveSelector, contextInfo: contextInfo, saved: false)
        }
    }

    /// Calls NSDocument's `document:didSave:contextInfo:` callback, as `super` would have.
    private func answer(_ delegate: Any?, didSave selector: Selector?, contextInfo: UnsafeMutableRawPointer?, saved: Bool) {
        guard let target = delegate as? NSObject, let selector, target.responds(to: selector) else { return }
        typealias DidSave = @convention(c) (NSObject, Selector, NSDocument, ObjCBool, UnsafeMutableRawPointer?) -> Void
        let implementation = unsafeBitCast(target.method(for: selector), to: DidSave.self)
        implementation(target, selector, self, ObjCBool(saved), contextInfo)
    }

    /// The name a Save As panel suggests for a copy: "<name> (annotated).pdf".
    var copySuggestedName: String {
        let base = ((fileURL?.lastPathComponent ?? displayName ?? "Document") as NSString).deletingPathExtension
        return "\(base) (annotated).pdf"
    }

    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        if let savePanelMessage {
            // The copy route: say why, and never suggest the original's own name.
            savePanel.message = savePanelMessage
            savePanel.nameFieldStringValue = copySuggestedName
            self.savePanelMessage = nil
        }
        return super.prepareSavePanel(savePanel)
    }

    /// Why saving to `url` is refused, or nil. Writing to the document's own file is allowed only
    /// for an `inPlace` document whose file is still the bytes loaded here: otherwise Save As or
    /// Save a Copy onto the same file would modify a signed original in place, or overwrite
    /// another app's version (A1, B7). The file is compared by identity, not by path.
    func refusalToSave(to url: URL) -> NSError? {
        guard let fileURL, Self.isSameFile(url, fileURL) else { return nil }
        if annotations?.saveability != .inPlace {
            return Self.saveError("Lectern won’t save over this document.", recovery: "It can’t be changed safely, so your annotations go into a copy. Choose another name or place for it. The original file hasn’t been changed.")
        }
        if let onDisk = try? Data(contentsOf: fileURL), onDisk != originalData {
            return Self.saveError("The file changed on disk since Lectern opened it.", recovery: "Lectern won’t save over the other app’s version. Choose another name or place for the copy. The file on disk hasn’t been changed.")
        }
        return nil
    }

    /// True when both URLs are the same file on disk (hard links and other paths included).
    nonisolated static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        // A symbolic link's own identifier is the link's, not its target's.
        let a = a.resolvingSymlinksInPath(), b = b.resolvingSymlinksInPath()
        let first = try? a.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        let second = try? b.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        guard let first = first as? NSObject, let second = second as? NSObject else { return false }
        return first.isEqual(second)
    }

    // MARK: Writing

    override nonisolated func canAsynchronouslyWrite(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType) -> Bool {
        false
    }

    override nonisolated func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] {
        switch saveOperation {
        case .saveOperation, .saveAsOperation, .saveToOperation: ["com.adobe.pdf"]
        default: []  // No autosave of any kind (A1).
        }
    }

    /// The only way Lectern writes a PDF: the original bytes plus the incremental writer's update
    /// (never PDFKit's `write(to:)` or `dataRepresentation()`). `url` is NSDocument's temporary
    /// file; the bytes are read back from it and checked before NSDocument swaps it into place,
    /// so a failed check leaves the original untouched.
    override nonisolated func write(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType, originalContentsURL absoluteOriginalContentsURL: URL?) throws {
        try MainActor.assumeIsolated {
            try writeAnnotatedFile(to: url, for: saveOperation, originalContentsURL: absoluteOriginalContentsURL)
        }
    }

    private func writeAnnotatedFile(to url: URL, for operation: NSDocument.SaveOperationType, originalContentsURL: URL?) throws {
        lastWrite = nil
        willWriteForTesting?()
        guard let editor = annotations else { throw Self.saveError("There is nothing to save.") }
        let original = originalData
        let changes = editor.pending.changes
        if operation != .saveOperation, let destination = saveDestination, let refusal = refusalToSave(to: destination) {
            // Checked again just before the bytes are written: the file may have changed since
            // the save began (another app, or a link made meanwhile).
            throw refusal
        }
        if operation == .saveOperation {
            guard editor.saveability == .inPlace, !fileWasRemoved else { throw Self.saveError(.copyOnly([])) }
            // Never append to bytes that are no longer the file (B7, Rule 7).
            if let current = originalContentsURL ?? fileURL, let onDisk = try? Data(contentsOf: current), onDisk != original {
                throw Self.saveError("The file changed on disk since Lectern opened it.", recovery: "Your annotations are still here. Use Save As to keep them in a new file, or reload the document.")
            }
        }
        var result: SaveResult?
        do throws(PDFSaveError) {
            switch operation {
            case .saveOperation:
                if !changes.isEmpty { result = try IncrementalWriter().saveInPlace(original: original, changes: changes) }
            case .saveAsOperation, .saveToOperation:
                if !changes.isEmpty { result = try IncrementalWriter().saveCopy(original: original, changes: changes) }
            default:
                throw .unsupported("autosave")
            }
        } catch {
            throw Self.saveError(error)
        }
        let bytes = result?.data ?? original
        try bytes.write(to: url)
        // Read back what reached the disk and check it before it replaces anything (A1).
        let written = try Data(contentsOf: url)
        var descriptors: [AnnotationDescriptor]?
        if let result {
            do throws(PDFSaveError) {
                descriptors = try SavedFileCheck.verify(written, original: original, against: result)
            } catch {
                throw Self.saveError(error)
            }
        } else if written != original {
            throw Self.saveError(.verificationFailed("the copy differs from the original"))
        }
        lastWrite = WrittenSave(operation: operation, data: bytes, descriptors: descriptors)
    }

    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType, completionHandler: @escaping ((any Error)?) -> Void) {
        if let refusal = refusalToSave(to: url) {
            completionHandler(refusal)
            return
        }
        saveDestination = url
        super.save(to: url, ofType: typeName, for: saveOperation) { error in
            MainActor.assumeIsolated {
                self.saveDestination = nil
                let written = self.lastWrite
                self.lastWrite = nil
                if error == nil, let written { self.didWrite(written, to: url) }
                completionHandler(error)
            }
        }
    }

    /// After a save reached the disk. Saving in place or as a new file makes the written bytes
    /// the document's original: the list empties and matching starts over from them, while the
    /// pages, the reader's place and the undo history stay. Save a Copy (B7) changes nothing here.
    private func didWrite(_ written: WrittenSave, to url: URL) {
        guard written.operation == .saveOperation || written.operation == .saveAsOperation, let editor = annotations else {
            readerWindowController?.documentDidSaveCopy(to: url)
            return
        }
        originalData = written.data
        resetCachedKey()
        // A Save As rescued a deleted or trashed file: the document is the new file now.
        if written.operation == .saveAsOperation { fileIsBack() }
        let descriptors = written.descriptors ?? (try? PDFSaveDocument(data: written.data).annotations()) ?? []
        let saveability = editor.saveability ?? .inPlace
        editor.didSave(written.data, descriptors: descriptors, saveability: saveability)
        updateChangeCount(.changeCleared)
        readerWindowController?.documentDidSave(asNewFile: written.operation == .saveAsOperation)
        // Re-check where it now lives (a Save As can make a copy-only document writable, or not).
        let data = written.data
        let readOnly = isReadOnlyLocation
        Task { [weak self, weak editor] in
            let info = await AnnotationFileInfo.inspect(data, readOnlyLocation: readOnly)
            guard let self, let editor, editor === self.annotations, editor.original == data else { return }
            editor.updateSaveability(info.saveability)
        }
    }

    // MARK: No autosave (A1)

    override var hasUnautosavedChanges: Bool { false }

    override func autosave(withImplicitCancellability autosavingIsImplicitlyCancellable: Bool, completionHandler: @escaping ((any Error)?) -> Void) {
        completionHandler(nil)
    }

    // MARK: Closing

    /// Closing with unsaved annotations happens only after Don't Save: the journal goes too.
    override func close() {
        readerWindowController?.documentWillClose(discardingAnnotations: hasUnsavedAnnotations)
        super.close()
    }

    // MARK: Errors

    /// NSDocument reports save errors here. They go through the window's presenter, which tests
    /// replace, so no test ever puts an alert on screen. The didPresent callback still fires.
    override func presentError(_ error: any Error, modalFor window: NSWindow, delegate: Any?, didPresent didPresentSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        let nsError = error as NSError
        func didPresent() {
            guard let target = delegate as? NSObject, let selector = didPresentSelector, target.responds(to: selector) else { return }
            typealias DidPresent = @convention(c) (NSObject, Selector, ObjCBool, UnsafeMutableRawPointer?) -> Void
            unsafeBitCast(target.method(for: selector), to: DidPresent.self)(target, selector, false, contextInfo)
        }
        // A cancelled save isn't an error to show, as AppKit's own presentation knows.
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSUserCancelledError {
            didPresent()
            return
        }
        // Errors that offer recovery need AppKit's alert, which runs the recovery attempter.
        guard let controller = readerWindowController, nsError.recoveryAttempter == nil else {
            super.presentError(error, modalFor: window, delegate: delegate, didPresent: didPresentSelector, contextInfo: contextInfo)
            return
        }
        controller.presenter.presentError(error, on: window) { didPresent() }
    }

    static func saveError(_ error: PDFSaveError) -> NSError {
        let reason: String = switch error {
        case .encrypted: "Lectern can’t save annotations into encrypted documents."
        case .copyOnly: "This document can only be saved as a copy. Use Save As."
        case .verificationFailed(let why): "The saved file didn’t pass Lectern’s check (\(why))."
        case .malformed(let why), .unsupported(let why): "Lectern couldn’t add to this file safely (\(why))."
        case .duplicateName(let name): "Two annotations would have the same name (\(name))."
        case .pageOutOfRange(let page): "An annotation refers to page \(page + 1), which the file doesn’t have."
        case .annotationNotFound(let ref): "An annotation (\(ref)) is no longer in the file."
        }
        return saveError("The document couldn’t be saved.", recovery: reason + " The original file hasn’t been changed, and your annotations are still open here.")
    }

    static func saveError(_ description: String, recovery: String? = nil) -> NSError {
        var info: [String: Any] = [NSLocalizedDescriptionKey: description]
        if let recovery { info[NSLocalizedRecoverySuggestionErrorKey] = recovery }
        return NSError(domain: "io.github.ronimoe.Lectern.save", code: 1, userInfo: info)
    }
}

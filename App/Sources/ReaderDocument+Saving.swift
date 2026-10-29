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
        let task = Task { [weak self, weak editor] in
            let info = await AnnotationFileInfo.inspect(data, readOnlyLocation: readOnly)
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
            super.save(withDelegate: delegate, didSave: didSaveSelector, contextInfo: contextInfo)
        case .nothingToSave:
            // Nothing changed: nothing is written. A caller waiting for an answer still gets one.
            if delegate != nil, !fileWasRemoved, fileURL != nil {
                super.save(withDelegate: delegate, didSave: didSaveSelector, contextInfo: contextInfo)
            }
        case .copy(let explanation):
            savePanelMessage = explanation
            runModalSavePanel(for: .saveAsOperation, delegate: delegate, didSave: didSaveSelector, contextInfo: contextInfo)
        case .refused(let refusal):
            readerWindowController?.explainAnnotationRefusal(refusal)
        case .changedOnDisk:
            readerWindowController?.fileChangedWithUnsavedAnnotations()
        }
    }

    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        if let savePanelMessage {
            savePanel.message = savePanelMessage
            self.savePanelMessage = nil
        }
        return super.prepareSavePanel(savePanel)
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
        guard let editor = annotations else { throw Self.saveError("There is nothing to save.") }
        let original = originalData
        let changes = editor.pending.changes
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
        super.save(to: url, ofType: typeName, for: saveOperation) { error in
            MainActor.assumeIsolated {
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

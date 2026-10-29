import AppKit
import PDFKit
import PDFSave
import Persistence
import ReaderCore
import ReaderKit
import ReaderUI

// MARK: Annotations (B4, Journey C)

extension ReaderWindowController {
    var annotations: AnnotationEditor? { readerDocument?.annotations }

    /// The document made a new annotation model (opened, or reloaded): connect it.
    func annotationEditorDidChange() {
        guard let editor = annotations else { return }
        editor.author = { [preferences] in preferences.annotationAuthor }
        editor.onRefusal = { [weak self] refusal in self?.explainAnnotationRefusal(refusal) }
        for pane in panes { pane.view.selectAnnotation(nil) }
        invalidateAnnotationList()
    }

    /// The background look at the file finished: annotations can be made, the forms line shows,
    /// and unsaved annotations from an earlier session are offered back.
    func annotationInfoDidLoad() {
        updateFormInfoLine()
        checkJournal()
        window?.toolbar?.validateVisibleItems()
    }

    /// After every annotation change: both panes show it (M0b Q7), the list follows, and the
    /// change list is journaled.
    func annotationsDidChange() {
        notifyAnnotationsChanged(from: focusedPane)
        for pane in panes { pane.view.updateSelectionAfterChange() }
        invalidateAnnotationList()
        recordJournal()
    }

    func explainAnnotationRefusal(_ refusal: AnnotationRefusal) {
        guard let window else { return }
        presenter.explainAnnotationRefusal(refusal, on: window, enterOwnerPassword: refusal.offersOwnerPassword ? { [weak self] in
            self?.promptForPassword(.removeRestrictions)
        } : nil)
    }

    /// Runs an annotation action, explaining a refusal instead of failing silently.
    func performAnnotationAction(_ body: (AnnotationEditor) throws(AnnotationRefusal) -> Void) {
        guard let editor = annotations else { return }
        do throws(AnnotationRefusal) {
            try body(editor)
        } catch {
            explainAnnotationRefusal(error)
        }
    }

    /// The colour new annotations get: the last one used (B4).
    var markupColor: AnnotationColorPreset { preferences.annotationColor }

    // MARK: Creating

    @objc func highlightSelection(_ sender: Any?) { markUpSelection(.highlight) }
    @objc func underlineSelection(_ sender: Any?) { markUpSelection(.underline) }
    @objc func strikeThroughSelection(_ sender: Any?) { markUpSelection(.strikeOut) }
    /// A note on selected text is a highlight with a comment (B4).
    @objc func commentOnSelection(_ sender: Any?) { markUpSelection(.note) }

    func markUpSelection(_ action: MarkupAction, in pane: ReaderPane? = nil) {
        let pane = pane ?? focusedPane
        guard let selection = pane.view.currentSelection else {
            explainAnnotationRefusal(.nothingToMark)
            return
        }
        let kind: MarkupKind = switch action {
        case .highlight, .note: .highlight
        case .underline: .underline
        case .strikeOut: .strikeOut
        }
        var created: [PDFAnnotation] = []
        performAnnotationAction { editor throws(AnnotationRefusal) in
            created = try editor.addMarkup(kind, covering: selection, color: markupColor)
        }
        guard let first = created.first else { return }
        pane.view.clearSelection()
        pane.view.hideSelectionBar()
        if action == .note {
            pane.view.selectAnnotation(first)
            editText(of: first, in: pane)
        }
    }

    /// Annotate ▸ Add Note: a note at the centre of the visible part of the current page.
    @objc func addNote(_ sender: Any?) {
        let view = pdfView
        let visible = view.unobscuredRectInView
        let center = CGPoint(x: visible.midX, y: visible.midY)
        guard let page = view.page(for: center, nearest: true) ?? view.currentPage else { return }
        addNote(on: page, at: view.convert(center, to: page), in: focusedPane)
    }

    /// The context menu's Add Note Here: at the clicked point.
    @objc func addNoteHere(_ sender: Any?) {
        guard let location = pdfView.contextClickLocation else {
            addNote(sender)
            return
        }
        addNote(on: location.page, at: location.point, in: focusedPane)
    }

    func addNote(on page: PDFPage, at point: CGPoint, in pane: ReaderPane) {
        var note: PDFAnnotation?
        performAnnotationAction { editor throws(AnnotationRefusal) in
            note = try editor.addNote(on: page, at: point, color: markupColor)
        }
        guard let note else { return }
        pane.view.selectAnnotation(note)
        editText(of: note, in: pane)
    }

    // MARK: Changing the selected annotation

    /// The annotation the focused pane has selected.
    var selectedAnnotation: PDFAnnotation? { pdfView.selectedAnnotation }

    @objc func deleteAnnotation(_ sender: Any?) {
        guard let annotation = selectedAnnotation else { return }
        performAnnotationAction { editor throws(AnnotationRefusal) in try editor.delete(annotation) }
        if annotation.page == nil { pdfView.selectAnnotation(nil) }
    }

    @objc func editAnnotationText(_ sender: Any?) {
        guard let annotation = selectedAnnotation else { return }
        editText(of: annotation, in: focusedPane)
    }

    /// Change Colour: the item's tag is the preset's index. It changes the selected annotation, if
    /// any, and becomes the colour for new ones.
    @objc func setAnnotationColor(_ sender: Any?) {
        let index = (sender as? NSMenuItem)?.tag ?? 0
        guard AnnotationColorPreset.allCases.indices.contains(index) else { return }
        let preset = AnnotationColorPreset.allCases[index]
        if let annotation = selectedAnnotation {
            changeColor(of: annotation, to: preset)
        } else {
            preferences.annotationColor = preset
        }
    }

    func changeColor(of annotation: PDFAnnotation, to preset: AnnotationColorPreset) {
        var changed = false
        performAnnotationAction { editor throws(AnnotationRefusal) in
            try editor.setColor(preset.pdfColor, of: annotation)
            changed = true
        }
        if changed { preferences.annotationColor = preset }
    }

    /// Opens the popover for a note's text or a markup comment.
    func editText(of annotation: PDFAnnotation, in pane: ReaderPane) {
        guard let page = annotation.page else { return }
        if let refusal = annotations?.refusal {
            explainAnnotationRefusal(refusal)
            return
        }
        let isNote = annotation.type == "Text"
        let heading = isNote ? "Note" : "Comment"
        let rect = pane.view.convert(annotation.bounds, from: page)
        presenter.editAnnotationText(heading: heading, text: annotation.contents ?? "", relativeTo: rect, of: pane.view) { [weak self, weak annotation] text in
            guard let self, let annotation, let text, annotation.page != nil else { return }
            performAnnotationAction { editor throws(AnnotationRefusal) in try editor.setContents(text, of: annotation) }
        }
    }

    /// A click on an annotation selected it; a double click also edits its text.
    func annotationClicked(_ annotation: PDFAnnotation, clickCount: Int, in pane: ReaderPane) {
        annotationsSection.select(ObjectIdentifier(annotation))
        if clickCount >= 2 { editText(of: annotation, in: pane) }
    }

    /// The items over an annotation, or over the page.
    func annotationMenuItems(for annotation: PDFAnnotation?, in view: ReaderPDFView) -> [NSMenuItem] {
        if annotation != nil {
            let colors = NSMenu(title: "Change Colour")
            for item in ReaderCommands.colorItems() { colors.addItem(item) }
            let colorItem = NSMenuItem(title: "Change Colour", action: nil, keyEquivalent: "")
            colorItem.submenu = colors
            return [
                NSMenuItem(title: annotation?.type == "Text" ? "Edit Note…" : "Edit Comment…", action: #selector(editAnnotationText(_:)), keyEquivalent: ""),
                colorItem,
                NSMenuItem(title: "Delete Annotation", action: #selector(deleteAnnotation(_:)), keyEquivalent: ""),
            ]
        }
        var items: [NSMenuItem] = []
        if view.currentSelection?.string?.isEmpty == false {
            items += [
                NSMenuItem(title: "Highlight", action: #selector(highlightSelection(_:)), keyEquivalent: ""),
                NSMenuItem(title: "Underline", action: #selector(underlineSelection(_:)), keyEquivalent: ""),
                NSMenuItem(title: "Strike Through", action: #selector(strikeThroughSelection(_:)), keyEquivalent: ""),
                NSMenuItem(title: "Add Comment…", action: #selector(commentOnSelection(_:)), keyEquivalent: ""),
            ]
        }
        items.append(NSMenuItem(title: "Add Note Here", action: #selector(addNoteHere(_:)), keyEquivalent: ""))
        return items
    }

    // MARK: The list (spec §5.3)

    @objc func showAnnotationList(_ sender: Any?) { showSidebarSection(.annotations) }

    func invalidateAnnotationList() {
        annotationListCache = nil
        if isSidebarVisible, sidebar.visibleSection == .annotations { refreshAnnotationList() }
    }

    func refreshAnnotationList() {
        annotationsSection.setItems(annotationList.map(\.item))
        annotationsSection.select(selectedAnnotation.map(ObjectIdentifier.init))
    }

    /// Every listed annotation, page by page, top to bottom. Built on demand: it reads every page.
    var annotationList: [(item: AnnotationListItem, annotation: PDFAnnotation)] {
        if let annotationListCache { return annotationListCache }
        guard let readerDocument, let pdf = readerDocument.pdfDocument, !pdf.isLocked else { return [] }
        var list: [(item: AnnotationListItem, annotation: PDFAnnotation)] = []
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index) else { continue }
            let listed = page.annotations.filter { AnnotationKindName.isListed(subtype: $0.type ?? "") }
                .sorted { a, b in a.bounds.maxY != b.bounds.maxY ? a.bounds.maxY > b.bounds.maxY : a.bounds.minX < b.bounds.minX }
            guard !listed.isEmpty else { continue }
            let label = readerDocument.label(forPageAt: index)
            for annotation in listed {
                list.append((Self.listItem(for: annotation, page: page, pageIndex: index, pageLabel: label), annotation))
            }
        }
        annotationListCache = list
        return list
    }

    static func listItem(for annotation: PDFAnnotation, page: PDFPage, pageIndex: Int, pageLabel: String) -> AnnotationListItem {
        let type = annotation.type ?? ""
        let rgb = AnnotationEditor.rgb(of: annotation)
        var excerpt = ""
        if ["Highlight", "Underline", "StrikeOut", "Squiggly"].contains(type) {
            let words = ReaderPDFView.hitRects(of: annotation).compactMap { page.selection(for: $0.insetBy(dx: 0, dy: $0.height * 0.2))?.string }
                .joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
            excerpt = words.count > 120 ? String(words.prefix(119)) + "…" : words
        }
        return AnnotationListItem(
            id: ObjectIdentifier(annotation), pageIndex: pageIndex, pageLabel: pageLabel,
            kind: AnnotationKindName.name(forSubtype: type),
            colorName: AnnotationColorPreset.describe(red: rgb.red, green: rgb.green, blue: rgb.blue),
            excerpt: excerpt, comment: annotation.contents ?? ""
        )
    }

    /// Jumps the focused pane to an annotation, adding a history entry (B2), and selects it.
    func jump(to annotation: PDFAnnotation) {
        guard let page = annotation.page, let document = pdfView.document else { return }
        let index = document.index(for: page)
        let box = page.bounds(for: pdfView.displayBox)
        let point = CGPoint(x: box.minX, y: min(box.maxY, annotation.bounds.maxY + 48))
        let destination = PDFDestination(page: page, at: point)
        guard let anchor = pdfView.anchor(for: destination), index != NSNotFound else { return }
        focusedPane.jump(to: anchor)
        pdfView.selectAnnotation(annotation)
        annotationsSection.select(ObjectIdentifier(annotation))
    }

    func jumpToListItem(_ item: AnnotationListItem) {
        guard let entry = annotationList.first(where: { $0.item.id == item.id }) else { return }
        jump(to: entry.annotation)
    }

    @objc func showNextAnnotation(_ sender: Any?) { stepAnnotation(by: 1) }
    @objc func showPreviousAnnotation(_ sender: Any?) { stepAnnotation(by: -1) }

    /// Go ▸ Next/Previous Annotation: from the selected one, or from where reading is.
    func stepAnnotation(by step: Int) {
        let list = annotationList
        guard !list.isEmpty else {
            NSSound.beep()
            return
        }
        let next: Int
        if let selected = selectedAnnotation, let at = list.firstIndex(where: { $0.annotation === selected }) {
            next = at + step
        } else {
            let page = pdfView.currentAnchor?.pageIndex ?? 0
            next = step > 0 ? (list.firstIndex { $0.item.pageIndex >= page } ?? list.count) : (list.lastIndex { $0.item.pageIndex <= page } ?? -1)
        }
        guard list.indices.contains(next) else {
            NSSound.beep()
            return
        }
        jump(to: list[next].annotation)
    }

    // MARK: Forms (A5)

    static let formFieldsMessage = "This document has form fields. Filling in forms isn’t supported yet."

    func updateFormInfoLine() {
        if isShowingContent, primaryPane.view.documentHasFormFields {
            formInfoLine.show(Self.formFieldsMessage)
        } else {
            formInfoLine.isHidden = true
        }
    }

    // MARK: Saving

    /// After a save in place or as a new file: the journal goes, and the stored state follows
    /// the file (a Save As gets its own record, so its journal never lands under the original's).
    func documentDidSave(asNewFile: Bool) {
        if let storedDocumentID { journal?.remove(storedDocumentID) }
        if asNewFile, let stateStore, let readerDocument, let url = readerDocument.fileURL, let pdf = readerDocument.pdfDocument {
            let stored = stateStore.open(url: url, data: readerDocument.originalData, pageCount: pdf.pageCount,
                                         fileIdentifiers: pdf.documentRef.map(DocumentIdentity.fileIdentifiers(of:)))
            adoptStoredDocument(stored.id)
            updateStoredState { $0.viewSettings = self.settings }
            saveAnchor()
        } else {
            refreshStoredIdentity()
        }
        notice.show("Saved")
    }

    func documentDidSaveCopy(to url: URL) {}

    func documentWillClose(discardingAnnotations: Bool) {
        // Closing with unsaved annotations only happens after Don't Save. A kept journal stays.
        if discardingAnnotations, let storedDocumentID { journal?.remove(storedDocumentID) }
    }

    // MARK: Crash journal (A1)

    func recordJournal() {
        guard let journal, let storedDocumentID, let editor = annotations, let hash = editor.originalSHA256 else { return }
        journal.record(JournalEntry(originalSHA256: hash, changes: editor.pending.changes), for: storedDocumentID)
    }

    /// Offers back unsaved annotations from a session that ended unexpectedly.
    func checkJournal() {
        guard !didCheckJournal, let journal, let storedDocumentID, let editor = annotations, let hash = editor.originalSHA256,
              let window, let readerDocument
        else { return }
        didCheckJournal = true
        let name = readerDocument.displayName ?? "This document"
        switch journal.lookup(storedDocumentID, currentSHA256: hash) {
        case .none:
            return
        case .matching(let entry):
            presenter.offerJournalRestore(name: name, changeCount: entry.changes.count, on: window) { [weak self] choice in
                guard let self else { return }
                switch choice {
                case .restore: restoreJournal(entry, id: storedDocumentID)
                case .discard: journal.discard(storedDocumentID)
                case .keep: journal.setAside(storedDocumentID)
                }
            }
        case .mismatched, .unreadable:
            let unreadable = journal.lookup(storedDocumentID, currentSHA256: hash) == .unreadable
            presenter.explainStaleJournal(name: name, unreadable: unreadable, on: window) { choice in
                // Kept journals move aside, where the document's new changes never touch them.
                if choice == .discard { journal.discard(storedDocumentID) } else { journal.setAside(storedDocumentID) }
            }
        }
    }

    func restoreJournal(_ entry: JournalEntry, id: UUID) {
        guard let editor = annotations, editor.pending.isEmpty else { return }
        do throws(AnnotationRefusal) {
            try editor.replay(entry.changes)
            // The changes are live again and journaled as such; a kept copy isn't needed.
            journal?.removeKept(id)
        } catch {
            // Nothing was applied: keep the journal, out of the way of new changes.
            journal?.setAside(id)
            explainAnnotationRefusal(error)
        }
    }

    // MARK: Changed on disk with unsaved annotations (B7)

    /// Asks once at a time: Reload (after a confirmation) or Save a Copy, which writes the
    /// version open here plus the unsaved annotations to a new file and opens it.
    func fileChangedWithUnsavedAnnotations() {
        guard !isAskingAboutChangedFile, let window, let readerDocument else { return }
        isAskingAboutChangedFile = true
        let name = readerDocument.displayName ?? "This document"
        presenter.askAboutChangedFile(name: name, on: window) { [weak self] choice in
            guard let self else { return }
            switch choice {
            case .reload:
                presenter.confirmDiscardingAnnotations(name: name, on: window) { [weak self] confirmed in
                    guard let self else { return }
                    guard confirmed else {
                        isAskingAboutChangedFile = false
                        return
                    }
                    Task {
                        await self.readerDocument?.reloadDiscardingAnnotations()
                        self.isAskingAboutChangedFile = false
                    }
                }
            case .saveCopy:
                let base = (name as NSString).deletingPathExtension
                presenter.chooseCopyDestination(suggestedName: "\(base) (annotated).pdf", on: window) { [weak self] url in
                    guard let self else { return }
                    guard let url else {
                        isAskingAboutChangedFile = false
                        return
                    }
                    saveCopyAfterChange(to: url)
                }
            }
        }
    }

    private func saveCopyAfterChange(to url: URL) {
        guard let readerDocument else { return }
        readerDocument.save(to: url, ofType: "com.adobe.pdf", for: .saveToOperation) { [weak self] error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let error {
                    self.isAskingAboutChangedFile = false
                    if let window = self.window { readerDocument.presentError(error, modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil) }
                    return
                }
                // The copy holds the annotations: open it, and show the file's new version here.
                self.openCopy(url)
                Task {
                    await readerDocument.reloadDiscardingAnnotations()
                    self.isAskingAboutChangedFile = false
                }
            }
        }
    }
}

extension ReaderPDFView {
    /// The part of the view not under the toolbar.
    var unobscuredRectInView: NSRect {
        let insets = safeAreaInsets
        return NSRect(x: bounds.minX + insets.left, y: isFlipped ? bounds.minY + insets.top : bounds.minY + insets.bottom,
                      width: bounds.width - insets.left - insets.right, height: bounds.height - insets.top - insets.bottom)
    }

    /// Drops a selection whose annotation was deleted, and redraws the outline.
    func updateSelectionAfterChange() {
        if let selected = selectedAnnotation, selected.page == nil || selected.page?.document !== document {
            selectAnnotation(nil)
        } else {
            selectAnnotation(selectedAnnotation)
        }
    }
}

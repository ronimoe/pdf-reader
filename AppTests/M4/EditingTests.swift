import AppKit
import PDFKit
import PDFSave
import ReaderCore
import ReaderKit
import ReaderUI
import Testing
@testable import Lectern

extension M4Tests {
    /// Editing and deleting annotations other apps wrote, through the matcher (B4, M4a).
    @MainActor @Suite struct ThirdParty {
        @Test func editsAndDeletesThirdPartyAnnotationsThroughTheMatcher() async throws {
            let harness = try await AnnotationHarness(corpus: "third-party-annots")
            defer { harness.close() }
            let original = harness.fileBytes
            let page = try #require(harness.pdf.page(at: 0))
            let highlight = try #require(page.annotations.first { $0.type == "Highlight" })
            let note = try #require(page.annotations.first { $0.type == "Text" })
            let square = try #require(page.annotations.first { $0.type == "Square" })
            let before = try SavedFile(original)
            let refs = Dictionary(uniqueKeysWithValues: before.descriptors.compactMap { d in d.ref.map { (d.subtype, $0) } })

            try harness.editor.setColor(AnnotationColorPreset.purple.pdfColor, of: highlight)
            try harness.editor.setContents("Edited by Lectern", of: note)
            try harness.editor.delete(square)
            #expect(harness.editor.pending.changes == [
                .editColor(refs["Highlight"]!, AnnotationColorPreset.purple.pdfColor),
                .editContents(refs["Text"]!, "Edited by Lectern"),
                .delete(refs["Square"]!),
            ])
            #expect(square.page == nil)

            // Undo before saving withdraws each change; redo brings it back.
            harness.undo.undo()
            #expect(square.page === page)
            #expect(harness.editor.pending.count == 2)
            harness.undo.undo()
            harness.undo.undo()
            #expect(harness.editor.pending.isEmpty)
            #expect(!harness.document.isDocumentEdited)
            harness.undo.redo()
            harness.undo.redo()
            harness.undo.redo()
            #expect(harness.editor.pending.count == 3)

            try await harness.save()
            let after = try SavedFile(harness.fileBytes)
            #expect(after.data.prefix(original.count) == original)
            #expect(try ExternalTool.qpdfCheck(harness.fileURL).status == 0)
            #expect(!after.descriptors.contains { $0.subtype == "Square" })
            #expect(after.descriptors.first { $0.subtype == "Highlight" }?.color == .rgb(AnnotationColorPreset.purple.pdfColor))
            #expect(after.descriptors.first { $0.subtype == "Text" }?.contents == "Edited by Lectern")

            // Deleting the note takes its popup along, in the file and on the page.
            try harness.editor.delete(note)
            #expect(!page.annotations.contains { $0.type == "Text" })
            try await harness.save()
            let final = try SavedFile(harness.fileBytes)
            #expect(!final.descriptors.contains { $0.subtype == "Text" || $0.subtype == "Popup" })
            #expect(try ExternalTool.qpdfCheck(harness.fileURL).status == 0)
        }

        @Test func anAmbiguousMatchIsRefusedWithAnExplanation() async throws {
            let harness = try await AnnotationHarness(data: TwinFixture.make())
            defer { harness.close() }
            let page = try #require(harness.pdf.page(at: 0))
            let twins = page.annotations.filter { $0.type == "Highlight" && $0.bounds.minY > 690 }
            #expect(twins.count == 2)
            let twin = try #require(twins.first)
            harness.view.selectAnnotation(twin)
            harness.controller.deleteAnnotation(nil)
            guard case .notMatched(.ambiguous)? = harness.presenter.refusals.last else {
                Issue.record("expected an ambiguous refusal, got \(harness.presenter.refusals)")
                return
            }
            #expect(AnnotationRefusal.notMatched(.ambiguous([])).message.contains("can’t tell which one"))
            #expect(twin.page === page)
            #expect(harness.editor.pending.isEmpty)
            #expect(throws: AnnotationRefusal.self) { try harness.editor.setColor(.yellow, of: twin) }
            #expect(throws: AnnotationRefusal.self) { try harness.editor.setContents("x", of: twin) }
            // The one that can be told apart still works.
            let single = try #require(page.annotations.first { $0.contents == "single" })
            try harness.editor.delete(single)
            #expect(harness.editor.pending.count == 1)
        }

        @Test func colourChangesAreOnlyOfferedForMarkupAndNotes() async throws {
            let harness = try await AnnotationHarness(corpus: "third-party-annots")
            defer { harness.close() }
            let square = try #require(harness.pdf.page(at: 0)?.annotations.first { $0.type == "Square" })
            #expect(throws: AnnotationRefusal.colorNotChangeable(kind: "Rectangle")) {
                try harness.editor.setColor(.yellow, of: square)
            }
        }
    }

    /// Forms stay read-only (A5).
    @MainActor @Suite struct Forms {
        @Test func widgetsCantBeClickedOrTabbedIntoAndSavingKeepsTheirData() async throws {
            let harness = try await AnnotationHarness(corpus: "acroform-filled")
            defer { harness.close() }
            let original = harness.fileBytes
            #expect(harness.view.documentHasFormFields)
            #expect(harness.controller.formInfoLine.message == "This document has form fields. Filling in forms isn’t supported yet.")
            let page = try #require(harness.pdf.page(at: 0))
            let widgets = page.annotations.filter { $0.type == "Widget" }
            #expect(widgets.count >= 4)
            let values = widgets.map { ($0.widgetStringValue, $0.buttonWidgetState) }
            harness.view.restore(try #require(harness.view.topAnchor(forPageAt: 0)))
            Spin.runLoop(0.1)
            for widget in widgets {
                let point = harness.view.convert(CGPoint(x: widget.bounds.midX, y: widget.bounds.midY), from: page)
                Synth.click(at: harness.view.convert(point, to: nil), in: harness.window)
                Spin.runLoop(0.05)
                #expect(harness.window.firstResponder === harness.view, "a field took focus")
            }
            Synth.key("\t", keyCode: 48, in: harness.window)
            Synth.key("x", keyCode: 7, in: harness.window)
            Spin.runLoop(0.1)
            #expect(widgets.map { ($0.widgetStringValue, $0.buttonWidgetState) }.elementsEqual(values) { $0 == $1 })
            #expect(widgets.allSatisfy { !$0.isReadOnly })
            // The info line can be dismissed and stays dismissed.
            harness.controller.formInfoLine.dismiss(nil)
            harness.controller.updateFormInfoLine()
            #expect(harness.controller.formInfoLine.message == nil)

            // Saving an annotation leaves every field and widget object byte-for-byte as it was.
            try harness.highlight("Lectern test corpus")
            try await harness.save()
            let before = try PDFSaveDocument(data: original)
            let after = try PDFSaveDocument(data: harness.fileBytes)
            let widgetRefs = try before.annotations().filter { $0.subtype == "Widget" }.compactMap(\.ref)
            #expect(widgetRefs.count >= 4)
            for ref in widgetRefs {
                #expect(try before.object(ref) == after.object(ref), "\(ref)")
            }
            #expect(try ExternalTool.qpdfCheck(harness.fileURL).status == 0)
        }
    }

    /// The selection control, clicking, the menus and the list (Journey C, spec §5.3).
    @MainActor @Suite struct Interface {
        @Test func theSelectionControlAppearsAfterSelectingAndEscapeHidesIt() async throws {
            let harness = try await AnnotationHarness(corpus: "classic-xref")
            defer { harness.close() }
            try harness.select("quick brown fox")
            #expect(harness.view.isSelectionBarVisible)
            #expect(harness.view.selectionBar.frame.intersects(harness.view.bounds))
            let labels = harness.view.selectionBar.actionButtons.values.map { $0.accessibilityLabel() ?? "" }.sorted()
            #expect(labels == ["Highlight", "Note", "Strike Through", "Underline"])
            #expect(harness.view.selectionBar.colorButton.accessibilityLabel() == "Colour: Yellow")
            harness.view.cancelOperation(nil)
            #expect(!harness.view.isSelectionBarVisible)
            // Its buttons create markup in the chosen colour, remembered for next time.
            try harness.select("lazy dog")
            harness.view.onMarkupColor?(.green)
            #expect(harness.preferences.annotationColor == .green)
            harness.view.selectionBar.perform(.underline)
            let created = try #require(harness.pdf.page(at: 0)?.annotations.first { $0.type == "Underline" })
            #expect(AnnotationEditor.rgb(of: created).isClose(to: AnnotationColorPreset.green.pdfColor, tolerance: 0.01))
            #expect(harness.view.currentSelection == nil)
            #expect(!harness.view.isSelectionBarVisible)
        }

        @Test func noteOnASelectionIsAHighlightWithAComment() async throws {
            let harness = try await AnnotationHarness(corpus: "classic-xref")
            defer { harness.close() }
            harness.presenter.annotationText = "My comment"
            try harness.select("quick brown fox")
            harness.view.selectionBar.perform(.note)
            #expect(harness.presenter.textEdits.map(\.heading) == ["Comment"])
            let highlight = try #require(harness.pdf.page(at: 0)?.annotations.first { $0.type == "Highlight" })
            #expect(highlight.contents == "My comment")
            guard case .addMarkup(let m)? = harness.editor.pending.changes.first else {
                Issue.record("expected one add")
                return
            }
            #expect(m.contents == "My comment" && harness.editor.pending.count == 1)
        }

        @Test func addNoteGoesToTheMiddleOfTheVisiblePageAndEditsItsText() async throws {
            let harness = try await AnnotationHarness(corpus: "classic-xref")
            defer { harness.close() }
            harness.presenter.annotationText = "Remember this"
            harness.controller.addNote(nil)
            let note = try #require(harness.pdf.page(at: 0)?.annotations.first { $0.type == "Text" })
            #expect(note.contents == "Remember this")
            #expect(harness.view.selectedAnnotation === note)
            let visible = harness.view.convert(harness.view.unobscuredRectInView, to: note.page!)
            #expect(visible.contains(CGPoint(x: note.bounds.minX, y: note.bounds.maxY)))
            // Cancelling the popover keeps the old text.
            harness.presenter.annotationText = nil
            harness.controller.editAnnotationText(nil)
            #expect(note.contents == "Remember this")
        }

        @Test func clickingSelectsAndDeleteKeyRemoves() async throws {
            let harness = try await AnnotationHarness(corpus: "third-party-annots")
            defer { harness.close() }
            let page = try #require(harness.pdf.page(at: 0))
            let square = try #require(page.annotations.first { $0.type == "Square" })
            harness.view.restore(try #require(harness.view.topAnchor(forPageAt: 0)))
            Spin.runLoop(0.1)
            let point = harness.view.convert(CGPoint(x: square.bounds.midX, y: square.bounds.midY), from: page)
            Synth.click(at: harness.view.convert(point, to: nil), in: harness.window)
            Spin.runLoop(0.05)
            #expect(harness.view.selectedAnnotation === square)
            #expect(harness.controller.validateMenuItem(NSMenuItem(title: "", action: #selector(ReaderWindowController.deleteAnnotation(_:)), keyEquivalent: "")))
            Synth.key("\u{7f}", keyCode: 51, in: harness.window)
            Spin.runLoop(0.05)
            #expect(square.page == nil)
            #expect(harness.view.selectedAnnotation == nil)
            #expect(harness.editor.pending.count == 1)
            // With nothing selected, ⌫ is disabled, so text fields keep Backspace.
            #expect(!harness.controller.validateMenuItem(NSMenuItem(title: "", action: #selector(ReaderWindowController.deleteAnnotation(_:)), keyEquivalent: "")))
        }

        @Test func theListGroupsByPageJumpsWithHistoryAndSteps() async throws {
            let harness = try await AnnotationHarness(corpus: "third-party-annots")
            defer { harness.close() }
            try harness.highlight("Lectern corpus", page: 1)
            harness.controller.showAnnotationList(nil)
            let items = harness.controller.annotationsSection.items
            #expect(items.map(\.pageIndex) == [0, 0, 0, 1])
            #expect(Set(items.map(\.kind)) == ["Highlight", "Note", "Rectangle"])
            let mupdf = try #require(items.first { $0.comment == "Highlight from MuPDF" })
            #expect(mupdf.colorName == "Green")
            #expect(mupdf.accessibilityLabel.hasPrefix("Highlight, Green, page 1"))
            #expect(items.last?.excerpt.contains("Lectern corpus") == true)
            #expect(items.last?.colorName == "Yellow")

            let historyBefore = harness.controller.primaryPane.history
            harness.controller.annotationsSection.activate(itemAt: 3)
            #expect(harness.view.selectedAnnotation?.page === harness.pdf.page(at: 1))
            #expect(harness.controller.primaryPane.history != historyBefore)
            #expect(harness.controller.primaryPane.canGoBack)
            harness.controller.showPreviousAnnotation(nil)
            #expect(harness.view.selectedAnnotation?.page === harness.pdf.page(at: 0))
            harness.controller.showNextAnnotation(nil)
            #expect(harness.view.selectedAnnotation?.page === harness.pdf.page(at: 1))
            // Changes show in the list.
            try harness.editor.delete(try #require(harness.view.selectedAnnotation))
            #expect(harness.controller.annotationsSection.items.count == 3)
        }

        @Test func bothPanesShowEveryChange() async throws {
            let harness = try await AnnotationHarness(corpus: "classic-xref")
            defer { harness.close() }
            let secondary = try #require(harness.controller.openSplit())
            Spin.runLoop(0.1)
            let before = (annotationLayerCount(harness.view), annotationLayerCount(secondary.view))
            try harness.highlight("quick brown fox")
            Spin.runLoop(0.2)
            #expect(annotationLayerCount(harness.view) == before.0 + 1)
            #expect(annotationLayerCount(secondary.view) == before.1 + 1)
        }

        /// ⌫ is a bare key equivalent: it must match the Delete key's character (0x7F, not
        /// NSBackspaceCharacter), and fire only while enabled, so a text field keeps Backspace
        /// whenever no annotation is selected on the page.
        @Test func aDisabledDeleteItemLetsBackspaceThrough() throws {
            let menu = MainMenu.make()
            let annotate = try #require(menu.items.first { $0.title == "Annotate" }?.submenu as? AnnotateMenu)
            let delete = try #require(annotate.items.first { $0.action == #selector(ReaderWindowController.deleteAnnotation(_:)) })
            let target = DeleteTarget()
            delete.target = target
            let backspace = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51
            ))
            // Nothing selected on the page: the menu doesn't claim the key at all.
            annotate.claimsDeleteKey = { false }
            #expect(!menu.performKeyEquivalent(with: backspace))
            #expect(target.deletes == 0)
            // An annotation selected on the page: ⌫ deletes it.
            annotate.claimsDeleteKey = { true }
            target.enabled = true
            #expect(menu.performKeyEquivalent(with: backspace))
            #expect(target.deletes == 1)
        }

        @Test func annotateMenuHasAShortcutForEveryAction() throws {
            let menu = MainMenu.make()
            let annotate = try #require(menu.items.first { $0.title == "Annotate" }?.submenu)
            let actions = annotate.items.filter { $0.action != nil && $0.submenu == nil }
            #expect(actions.count == 7, "\(actions.map(\.title))")
            #expect(actions.allSatisfy { !$0.keyEquivalent.isEmpty }, "\(actions.filter { $0.keyEquivalent.isEmpty }.map(\.title))")
            let colors = try #require(annotate.items.first { $0.title == "Colour" }?.submenu)
            #expect(colors.items.map(\.title) == AnnotationColorPreset.allCases.map(\.name))
            #expect(colors.items.allSatisfy { !$0.keyEquivalent.isEmpty && $0.image?.accessibilityDescription != nil })
            let go = try #require(menu.items.first { $0.title == "Go" }?.submenu)
            #expect(go.items.contains { $0.action == #selector(ReaderWindowController.showNextAnnotation(_:)) && !$0.keyEquivalent.isEmpty })
            #expect(go.items.contains { $0.action == #selector(ReaderWindowController.showPreviousAnnotation(_:)) && !$0.keyEquivalent.isEmpty })
        }
    }

    /// Real-world papers and reports through create → save → reopen.
    @MainActor @Suite struct RealWorld {
        @Test(arguments: [
            ("arxiv-2208.04284v5", "Generalization Bounds"),
            ("arxiv-2310.12457v2", "MuseGNN"),
            ("nasa-tm-20180002207", "Marshall Space Flight Center"),
            ("nasa-tm-2020-220520", "Integrated Radio"),
        ])
        func createSaveReopen(name: String, phrase: String) async throws {
            let harness = try await AnnotationHarness(corpus: name)
            let original = harness.fileBytes
            #expect(harness.editor.saveability == .inPlace)
            let highlight = try harness.highlight(phrase)
            try harness.editor.setContents("Read again", of: highlight)
            let page = try #require(harness.pdf.page(at: 0))
            let note = try harness.editor.addNote(on: page, at: CGPoint(x: 72, y: 72), color: .blue, text: "Note on page 1")
            let names = [highlight, note].compactMap { $0.value(forAnnotationKey: .name) as? String }
            try await harness.save()
            harness.close()

            let saved = try Data(contentsOf: harness.fileURL)
            #expect(saved.prefix(original.count) == original)
            let qpdf = try ExternalTool.qpdfCheck(harness.fileURL)
            #expect(qpdf.status == 0, "\(qpdf.output.prefix(500))")
            // Reopened as a document, the annotations are there.
            let reopened = try ReaderDocument.opened(harness.fileURL)
            let pdf = try #require(reopened.pdfDocument)
            let all = (0..<pdf.pageCount).flatMap { pdf.page(at: $0)?.annotations ?? [] }
            for name in names {
                #expect(all.filter { ($0.value(forAnnotationKey: .name) as? String) == name }.count == 1)
            }
            #expect(all.first { ($0.value(forAnnotationKey: .name) as? String) == names[0] }?.contents == "Read again")
            reopened.close()
        }
    }
}

@MainActor
private final class DeleteTarget: NSObject, NSMenuItemValidation {
    var enabled = false
    var deletes = 0
    @objc func deleteAnnotation(_ sender: Any?) { deletes += 1 }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { enabled }
}

import AppKit
import PDFKit
import PDFSave
import ReaderCore
import ReaderKit
import Testing
@testable import Lectern

extension M4Tests {
    /// Journey C end to end: create, save through NSDocument, re-read the bytes (A1, B4).
    @MainActor @Suite struct EndToEnd {
        @Test func highlightNoteAndCommentSaveInPlace() async throws {
            let harness = try await AnnotationHarness(corpus: "classic-xref")
            defer { harness.close() }
            let original = harness.fileBytes
            #expect(harness.editor.saveability == .inPlace)
            #expect(harness.document.saveRoute == .nothingToSave)

            let highlight = try harness.highlight("quick brown fox")
            let page = try #require(harness.pdf.page(at: 0))
            let note = try harness.editor.addNote(on: page, at: CGPoint(x: 500, y: 700), color: .green, text: "A sticky note")
            let underline = try harness.highlight("lazy dog", kind: .underline)
            try harness.editor.setContents("A comment on the underline", of: underline)
            #expect(harness.document.isDocumentEdited)
            #expect(harness.document.saveRoute == .inPlace)
            #expect(harness.editor.pending.count == 3)

            try await harness.save()
            let saved = harness.fileBytes
            // 1. The original bytes are a prefix of the result.
            #expect(saved.count > original.count)
            #expect(saved.prefix(original.count) == original)
            // 2. qpdf --check passes.
            let qpdf = try ExternalTool.qpdfCheck(harness.fileURL)
            #expect(qpdf.status == 0, "qpdf --check: \(qpdf.output)")
            // 3. PDFKit shows the annotations, with their comments.
            let file = try SavedFile(saved)
            let names = [highlight, note, underline].map { $0.value(forAnnotationKey: .name) as? String }
            for (name, type) in zip(names, ["Highlight", "Text", "Underline"]) {
                let found = file.annotations(named: try #require(name))
                #expect(found.count == 1 && found.first?.type == type, "\(type)")
            }
            #expect(file.annotations(named: names[1]!).first?.contents == "A sticky note")
            #expect(file.annotations(named: names[2]!).first?.contents == "A comment on the underline")
            // 4. No author or dates without an author set (B4).
            let update = appendedText(saved, after: original)
            #expect(update.range(of: #"/T[\s(<]"#, options: .regularExpression) == nil, "/T in \(update)")
            #expect(update.range(of: #"/M[\s(<]"#, options: .regularExpression) == nil)
            #expect(!update.contains("/CreationDate"))
            #expect(!update.contains("D:20"))
            if !NSFullUserName().isEmpty { #expect(!update.contains(NSFullUserName())) }
            #expect(file.lecternDescriptors.allSatisfy { $0.author == nil })

            // After the save: clean, the bytes are the new original, and the place is kept.
            #expect(!harness.document.isDocumentEdited)
            #expect(harness.document.originalData == saved)
            #expect(harness.editor.pending.isEmpty)
            #expect(harness.view.document === harness.pdf)
        }

        @Test func anAuthorFromSettingsIsWrittenAsT() async throws {
            let harness = try await AnnotationHarness(corpus: "classic-xref")
            defer { harness.close() }
            harness.preferences.annotationAuthor = "Ada Reader"
            harness.controller.annotationEditorDidChange()
            let highlight = try harness.highlight("quick brown fox")
            #expect(highlight.userName == "Ada Reader")
            try await harness.save()
            let file = try SavedFile(harness.fileBytes)
            #expect(file.lecternDescriptors.map(\.author) == ["Ada Reader"])
        }

        @Test func pdfKitsOwnAuthorAndDateAreClearedOnCreation() async throws {
            let harness = try await AnnotationHarness(corpus: "classic-xref")
            defer { harness.close() }
            let highlight = try harness.highlight("quick brown fox")
            let page = try #require(harness.pdf.page(at: 0))
            let note = try harness.editor.addNote(on: page, at: CGPoint(x: 400, y: 400), color: .yellow)
            for annotation in [highlight, note] + [note.popup].compactMap({ $0 }) {
                #expect(annotation.userName == nil || annotation.userName?.isEmpty == true)
                #expect(annotation.modificationDate == nil)
            }
            #expect((highlight.value(forAnnotationKey: .name) as? String)?.hasPrefix("lectern-") == true)
        }

        @Test func saveCommandWritesInPlaceAndTheSecondSaveAppendsAgain() async throws {
            let harness = try await AnnotationHarness(corpus: "classic-xref")
            defer { harness.close() }
            try harness.highlight("quick brown fox")
            // ⌘S itself: the File menu's Save action.
            harness.document.save(nil)
            harness.wait { !harness.document.isDocumentEdited }
            #expect(!harness.document.isDocumentEdited)
            let first = harness.fileBytes
            #expect(try SavedFile(first).lecternDescriptors.count == 1)
            try harness.highlight("lazy dog", kind: .strikeOut)
            try await harness.save()
            let second = harness.fileBytes
            #expect(second.prefix(first.count) == first)
            #expect(try SavedFile(second).lecternDescriptors.map(\.subtype).sorted() == ["Highlight", "StrikeOut"])
            #expect(try ExternalTool.qpdfCheck(harness.fileURL).status == 0)
        }

        @Test func nothingIsWrittenWithoutChanges() async throws {
            let harness = try await AnnotationHarness(corpus: "classic-xref")
            defer { harness.close() }
            let before = harness.fileBytes
            let modified = try FileManager.default.attributesOfItem(atPath: harness.fileURL.path)[.modificationDate] as? Date
            harness.document.save(nil)
            Spin.runLoop(0.3)
            #expect(harness.fileBytes == before)
            #expect(try FileManager.default.attributesOfItem(atPath: harness.fileURL.path)[.modificationDate] as? Date == modified)
        }
    }

    /// Undo and redo of every action, before and after a save (B4).
    @MainActor @Suite struct UndoRedo {
        @Test func addThenUndoAndRedo() async throws {
            let harness = try await AnnotationHarness(corpus: "classic-xref")
            defer { harness.close() }
            let highlight = try harness.highlight("quick brown fox")
            #expect(harness.undo.undoActionName == "Highlight")
            harness.undo.undo()
            #expect(harness.editor.pending.isEmpty)
            #expect(highlight.page == nil)
            #expect(!harness.document.isDocumentEdited)
            harness.undo.redo()
            #expect(harness.editor.pending.count == 1)
            #expect(highlight.page === harness.pdf.page(at: 0))
            #expect(harness.document.isDocumentEdited)
        }

        @Test func editsOfAnUnsavedAnnotationUndoInsideItsAdd() async throws {
            let harness = try await AnnotationHarness(corpus: "classic-xref")
            defer { harness.close() }
            let highlight = try harness.highlight("quick brown fox")
            try harness.editor.setColor(AnnotationColorPreset.blue.pdfColor, of: highlight)
            try harness.editor.setContents("why", of: highlight)
            guard case .addMarkup(let m)? = harness.editor.pending.changes.first else {
                Issue.record("expected one add")
                return
            }
            #expect(harness.editor.pending.count == 1)
            #expect(m.color == AnnotationColorPreset.blue.pdfColor && m.contents == "why")
            harness.undo.undo()
            harness.undo.undo()
            guard case .addMarkup(let back)? = harness.editor.pending.changes.first else {
                Issue.record("expected one add")
                return
            }
            #expect(back.color == AnnotationColorPreset.yellow.pdfColor && back.contents == nil)
            #expect(highlight.contents == nil || highlight.contents == "")
        }

        @Test func undoAfterSaveDeletesWhatWasSavedAndRedoCancelsIt() async throws {
            let harness = try await AnnotationHarness(corpus: "classic-xref")
            defer { harness.close() }
            let highlight = try harness.highlight("quick brown fox")
            let name = try #require(highlight.value(forAnnotationKey: .name) as? String)
            try await harness.save()
            let saved = try SavedFile(harness.fileBytes)
            let ref = try #require(saved.lecternDescriptors.first?.ref)

            harness.undo.undo()
            // A new unsaved change: delete the object the save wrote.
            #expect(harness.editor.pending.changes == [.delete(ref)])
            #expect(harness.document.isDocumentEdited)
            #expect(highlight.page == nil)

            harness.undo.redo()
            #expect(harness.editor.pending.isEmpty)
            #expect(highlight.page != nil)
            #expect(!harness.document.isDocumentEdited)

            // Undo again and save: the highlight leaves the file.
            harness.undo.undo()
            try await harness.save()
            #expect(try SavedFile(harness.fileBytes).annotations(named: name).isEmpty)
            #expect(try ExternalTool.qpdfCheck(harness.fileURL).status == 0)

            // Redo after that save recreates it, under a new name.
            harness.undo.redo()
            guard case .addMarkup(let recreated)? = harness.editor.pending.changes.first else {
                Issue.record("expected a recreated highlight, got \(harness.editor.pending.changes)")
                return
            }
            #expect(harness.editor.pending.count == 1)
            #expect(recreated.name != name)
            #expect(recreated.quads.count == 1)
            try await harness.save()
            let final = try SavedFile(harness.fileBytes)
            #expect(final.annotations(named: recreated.name).count == 1)
        }

        @Test func undoOfAColourChangeAfterSaveIsANewChange() async throws {
            let harness = try await AnnotationHarness(corpus: "classic-xref")
            defer { harness.close() }
            let highlight = try harness.highlight("quick brown fox")
            try await harness.save()
            try harness.editor.setColor(AnnotationColorPreset.red.pdfColor, of: highlight)
            try await harness.save()
            let ref = try #require(try SavedFile(harness.fileBytes).lecternDescriptors.first?.ref)
            harness.undo.undo()
            #expect(harness.editor.pending.changes == [.editColor(ref, AnnotationColorPreset.yellow.pdfColor)])
            harness.undo.redo()
            // Back to the saved colour: nothing to save.
            #expect(harness.editor.pending.isEmpty)
        }
    }

    /// Signed, certified and other copy-only files (A1): the original is never modified.
    @MainActor @Suite struct CopyOnly {
        @Test(arguments: [("signed-approval", [CopyOnlyReason.signed]), ("certified-docmdp", [.certified, .signed])])
        func savesAnnotationsInACopy(name: String, reasons: [CopyOnlyReason]) async throws {
            let harness = try await AnnotationHarness(corpus: name)
            defer { harness.close() }
            let original = harness.fileBytes
            #expect(harness.editor.saveability == .copyOnly(reasons))
            try harness.highlight("quick brown fox")
            guard case .copy(let explanation) = harness.document.saveRoute else {
                Issue.record("expected the copy route, got \(harness.document.saveRoute)")
                return
            }
            #expect(explanation.contains(reasons[0] == .signed ? "signed" : "certified"))
            #expect(explanation.contains("saves your annotations in a copy"))

            // Saving over the file is refused, and leaves it untouched.
            await #expect(throws: (any Error).self) { try await harness.save() }
            #expect(harness.fileBytes == original)
            #expect(harness.document.isDocumentEdited)

            // Save As writes saveCopy to the new file, and the window then refers to it.
            let copy = harness.folder.url.appending(path: "\(name) copy.pdf")
            try await harness.save(to: copy, .saveAsOperation)
            #expect(harness.fileBytes == original)
            #expect(harness.document.fileURL?.standardizedFileURL == copy.standardizedFileURL)
            let copyBytes = try Data(contentsOf: copy)
            #expect(copyBytes.prefix(original.count) == original)
            #expect(try SavedFile(copyBytes).lecternDescriptors.count == 1)
            #expect(try ExternalTool.qpdfCheck(copy).status == 0)
            #expect(!harness.document.isDocumentEdited)
            #expect(harness.document.originalData == copyBytes)
        }
    }

    /// Encrypted files can't be saved with annotations (A1, §4.3); restricted ones explain (B6).
    @MainActor @Suite struct Unsupported {
        @Test func encryptedFileRefusesAnnotationsWithAnExplanation() async throws {
            let folder = try TemporaryFolder()
            let url = try folder.write(try Corpus.data("encrypted-aes256"), to: "encrypted.pdf")
            let harness = try await AnnotationHarness(file: url, folder: folder, password: "user-pass")
            defer { harness.close() }
            await harness.waitForInspection()
            #expect(harness.editor.saveability == .unsupported(.encrypted))
            try harness.select("quick brown fox")
            harness.controller.highlightSelection(nil)
            #expect(harness.presenter.refusals == [.cannotSave(.encrypted)])
            #expect(harness.editor.pending.isEmpty)
            #expect(harness.pdf.page(at: 0)?.annotations.isEmpty == true)
            #expect(AnnotationRefusal.cannotSave(.encrypted).message.contains("encrypted"))
            // Nothing to save, and ⌘S writes nothing.
            #expect(harness.document.saveRoute == .nothingToSave)
        }

        @Test func restrictedCommentingExplainsAndOffersTheOwnerPassword() async throws {
            let harness = try await AnnotationHarness(corpus: "encrypted-aes256-owner-only")
            defer { harness.close() }
            #expect(harness.pdf.allowsCommenting == false)
            try harness.select("quick brown fox")
            harness.controller.highlightSelection(nil)
            #expect(harness.presenter.refusals == [.commentingNotAllowed])
            #expect(harness.presenter.ownerPasswordOffers == 1)
            // The owner password lifts the restriction, but the file is still encrypted.
            #expect(harness.controller.submitPassword("owner-pass", remember: false, purpose: .removeRestrictions))
            try harness.select("quick brown fox")
            harness.controller.highlightSelection(nil)
            #expect(harness.presenter.refusals.last == .cannotSave(.encrypted))
        }

        @Test func actionsWaitForTheSaveCheck() throws {
            let document = try ReaderDocument.loaded(try Corpus.data("classic-xref"))
            let editor = try #require(document.annotations)
            #expect(editor.refusal == .stillChecking)
        }
    }
}

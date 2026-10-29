import AppKit
import PDFKit
import PDFSave
import Persistence
import ReaderCore
import ReaderKit
import Testing
@testable import Lectern

extension M4Tests {
    /// The crash journal (A1): restore, discard, and a file that changed since.
    @MainActor @Suite struct CrashJournal {
        /// Makes changes, writes the journal, and "crashes" (the document is never closed).
        func crashedSession(_ folder: TemporaryFolder) async throws -> (url: URL, store: DocumentStateStore, journal: AnnotationJournal, changes: [AnnotationChange]) {
            let url = try folder.write(try Corpus.data("third-party-annots"), to: "notes.pdf")
            let first = try await AnnotationHarness(file: url, folder: folder)
            try first.highlight("quick brown fox")
            let page = try #require(first.pdf.page(at: 0))
            let mupdfHighlight = try #require(page.annotations.first { $0.type == "Highlight" && $0.contents == "Highlight from MuPDF" })
            try first.editor.setColor(AnnotationColorPreset.pink.pdfColor, of: mupdfHighlight)
            let square = try #require(page.annotations.first { $0.type == "Square" })
            try first.editor.delete(square)
            let changes = first.editor.pending.changes
            #expect(changes.count == 3)
            first.journal.flush(try #require(first.controller.storedDocumentID))
            first.store.flush()
            first.abandon()
            return (url, first.store, first.journal, changes)
        }

        @Test func restoresUnsavedAnnotationsForTheSameBytes() async throws {
            let folder = try TemporaryFolder()
            let crashed = try await crashedSession(folder)
            let second = try await AnnotationHarness(file: crashed.url, folder: folder, store: crashed.store, journal: crashed.journal)
            defer { second.close() }
            #expect(second.presenter.journalOffers == [3])
            #expect(second.editor.pending.changes == crashed.changes)
            let page = try #require(second.pdf.page(at: 0))
            #expect(page.annotations.contains { $0.type == "Highlight" && second.editor.isUnsaved($0) })
            #expect(!page.annotations.contains { $0.type == "Square" })
            #expect(page.annotations.first { $0.contents == "Highlight from MuPDF" }.map(AnnotationEditor.rgb(of:))?.isClose(to: AnnotationColorPreset.pink.pdfColor, tolerance: 0.01) == true)
            #expect(second.document.isDocumentEdited)
            // And it saves.
            try await second.save()
            let file = try SavedFile(second.fileBytes)
            #expect(file.lecternDescriptors.count == 1)
            #expect(!file.descriptors.contains { $0.subtype == "Square" })
            #expect(second.journal.lookup(try #require(second.controller.storedDocumentID), currentSHA256: "x") == .none)
        }

        @Test func discardChoiceRemovesItWithoutApplying() async throws {
            let folder = try TemporaryFolder()
            let crashed = try await crashedSession(folder)
            let second = try await AnnotationHarness(file: crashed.url, folder: folder, store: crashed.store, journal: crashed.journal, journalChoice: .discard)
            defer { second.close() }
            let id = try #require(second.controller.storedDocumentID)
            #expect(second.presenter.journalOffers == [3])
            #expect(second.editor.pending.isEmpty)
            #expect(!second.document.isDocumentEdited)
            #expect(second.journal.lookup(id, currentSHA256: second.editor.originalSHA256!) == .none)
        }

        @Test func aChangedFileIsExplainedAndNeverDeletedSilently() async throws {
            let folder = try TemporaryFolder()
            let crashed = try await crashedSession(folder)
            // Another app saves a different version.
            let changed = try IncrementalWriter().saveInPlace(original: try Data(contentsOf: crashed.url), changes: [
                .addNote(NewNote(pageIndex: 1, origin: PDFPoint(x: 100, y: 100), contents: "elsewhere")),
            ]).data
            try changed.write(to: crashed.url)
            let keep = try await AnnotationHarness(file: crashed.url, folder: folder, store: crashed.store, journal: crashed.journal, staleJournalChoice: .keep)
            #expect(keep.presenter.staleJournalExplanations == [false])
            #expect(keep.presenter.journalOffers.isEmpty)
            #expect(keep.editor.pending.isEmpty)
            let id = try #require(keep.controller.storedDocumentID)
            guard case .mismatched = keep.journal.lookup(id, currentSHA256: keep.editor.originalSHA256!) else {
                Issue.record("Keep must leave the journal")
                return
            }
            keep.abandon()
            let discard = try await AnnotationHarness(file: crashed.url, folder: folder, store: crashed.store, journal: crashed.journal, staleJournalChoice: .discard)
            defer { discard.close() }
            #expect(discard.presenter.staleJournalExplanations == [false])
            #expect(discard.journal.lookup(id, currentSHA256: "any") == .none)
        }

        @Test func dontSaveOnCloseDeletesTheJournal() async throws {
            let harness = try await AnnotationHarness(corpus: "classic-xref")
            try harness.highlight("quick brown fox")
            let id = try #require(harness.controller.storedDocumentID)
            harness.journal.flush(id)
            #expect(harness.journal.lookup(id, currentSHA256: harness.editor.originalSHA256!) != .none)
            // Closing with unsaved annotations happens only after Don't Save.
            harness.close()
            #expect(harness.journal.lookup(id, currentSHA256: "any") == .none)
        }

        @Test func aSuccessfulSaveDeletesTheJournal() async throws {
            let harness = try await AnnotationHarness(corpus: "classic-xref")
            defer { harness.close() }
            try harness.highlight("quick brown fox")
            let id = try #require(harness.controller.storedDocumentID)
            harness.journal.flush(id)
            try await harness.save()
            #expect(harness.journal.lookup(id, currentSHA256: "any") == .none)
        }
    }

    /// B7: the file changed on disk while annotations are unsaved.
    @MainActor @Suite struct ChangedOnDisk {
        func changeFileOnDisk(_ harness: AnnotationHarness) throws -> Data {
            let other = try IncrementalWriter().saveInPlace(original: harness.fileBytes, changes: [
                .addNote(NewNote(pageIndex: 0, origin: PDFPoint(x: 50, y: 50), contents: "from another app")),
            ]).data
            try other.write(to: harness.fileURL)
            return other
        }

        @Test func reloadAfterConfirmationDiscardsTheAnnotations() async throws {
            let harness = try await AnnotationHarness(corpus: "classic-xref")
            defer { harness.close() }
            harness.presenter.changedFileChoice = .reload
            try harness.highlight("quick brown fox")
            let id = try #require(harness.controller.storedDocumentID)
            harness.journal.flush(id)
            let other = try changeFileOnDisk(harness)
            #expect(await harness.document.reloadFromDiskIfChanged() == false)
            #expect(harness.presenter.changedFileQuestions == 1)
            #expect(harness.presenter.discardConfirmations == 1)
            await harness.settle { harness.document.originalData == other }
            #expect(harness.document.originalData == other)
            #expect(harness.editor.pending.isEmpty)
            #expect(!harness.document.isDocumentEdited)
            #expect(harness.pdf.page(at: 0)?.annotations.contains { $0.contents == "from another app" } == true)
            #expect(harness.journal.lookup(id, currentSHA256: "any") == .none)
            #expect(!harness.undo.canUndo)
        }

        @Test func cancellingTheConfirmationKeepsEverything() async throws {
            let harness = try await AnnotationHarness(corpus: "classic-xref")
            defer { harness.close() }
            harness.presenter.changedFileChoice = .reload
            harness.presenter.confirmsDiscard = false
            try harness.highlight("quick brown fox")
            let loaded = harness.document.originalData
            _ = try changeFileOnDisk(harness)
            await harness.document.reloadFromDiskIfChanged()
            Spin.runLoop(0.2)
            #expect(harness.document.originalData == loaded)
            #expect(harness.editor.pending.count == 1)
            // ⌘S now asks again instead of writing over the changed file.
            #expect(harness.document.saveRoute == .changedOnDisk)
            await #expect(throws: (any Error).self) { try await harness.save() }
        }

        @Test func saveACopyWritesTheLoadedVersionPlusTheAnnotationsAndOpensIt() async throws {
            let harness = try await AnnotationHarness(corpus: "classic-xref")
            defer { harness.close() }
            let loaded = harness.document.originalData
            let copy = harness.folder.url.appending(path: "copy.pdf")
            harness.presenter.changedFileChoice = .saveCopy
            harness.presenter.copyDestination = copy
            let highlight = try harness.highlight("quick brown fox")
            let name = try #require(highlight.value(forAnnotationKey: .name) as? String)
            let other = try changeFileOnDisk(harness)
            await harness.document.reloadFromDiskIfChanged()
            await harness.settle { harness.document.originalData == other }
            #expect(harness.presenter.copyDestinationRequests == ["classic-xref (annotated).pdf"])
            let copyBytes = try Data(contentsOf: copy)
            #expect(copyBytes.prefix(loaded.count) == loaded)
            let file = try SavedFile(copyBytes)
            #expect(file.annotations(named: name).count == 1)
            #expect(!file.descriptors.contains { $0.contents == "from another app" })
            #expect(try ExternalTool.qpdfCheck(copy).status == 0)
            #expect(harness.openedCopies.map(\.standardizedFileURL) == [copy.standardizedFileURL])
            // The other app's version is never overwritten; the window now shows it.
            #expect(harness.fileBytes == other)
            #expect(harness.document.originalData == other)
            #expect(harness.document.fileURL?.standardizedFileURL == harness.fileURL.standardizedFileURL)
        }

        @Test func aCleanDocumentStillReloadsSilently() async throws {
            let harness = try await AnnotationHarness(corpus: "classic-xref")
            defer { harness.close() }
            let other = try changeFileOnDisk(harness)
            #expect(await harness.document.reloadFromDiskIfChanged())
            #expect(harness.presenter.changedFileQuestions == 0)
            #expect(harness.document.originalData == other)
        }
    }
}

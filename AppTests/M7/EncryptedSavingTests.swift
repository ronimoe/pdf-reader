import AppKit
import PDFKit
import PDFSave
import Persistence
import ReaderCore
import ReaderKit
import Testing
@testable import Lectern

/// M7: annotations saved into encrypted documents, end to end through the app's save path
/// (architecture §3.2 item 7, §4.3), with the crash journal sealed (§6).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(10)), .noUI)
struct EncryptedSavingTests {
    nonisolated struct Variant: Sendable, CustomTestStringConvertible {
        let fixture: String
        /// What the app is unlocked with; nil for a file that opens without a password. The
        /// non-ASCII-password files use their owner password: PDFKit can't unlock theirs.
        let password: String?
        var testDescription: String { fixture }
    }

    nonisolated static let variants: [Variant] = [
        Variant(fixture: "encrypted-r2-rc4-40", password: "user-pass"),
        Variant(fixture: "encrypted-r3-rc4-annotated", password: nil),
        Variant(fixture: "encrypted-r4-rc4", password: "owner-pass"),
        Variant(fixture: "encrypted-r4-aes128-objstm", password: "user-pass"),
        Variant(fixture: "encrypted-r4-cleartext-metadata", password: nil),
        Variant(fixture: "encrypted-r4-identity-strings", password: nil),
        Variant(fixture: "encrypted-aes256", password: "user-pass"),
        Variant(fixture: "encrypted-r6-objstm-restricted", password: nil),
        Variant(fixture: "encrypted-r6-unicode", password: "owner-pass"),
    ]

    /// Saves in place, twice, and checks every safety net: the original is a prefix, the read-back
    /// decrypts to the annotations, qpdf accepts the file with the password, the window stays
    /// unlocked, and the document key (the Keychain entry, positions, bookmarks) doesn't move.
    @Test(arguments: variants) func savesInPlaceTwice(_ v: Variant) async throws {
        let harness = try await AnnotationHarness(corpus: v.fixture, password: v.password)
        defer { harness.close() }
        #expect(!harness.pdf.isLocked)
        #expect(harness.editor.saveability == .inPlace)
        #expect(harness.editor.info?.descriptorsAreComplete == true)
        #expect(harness.editor.info?.isEncrypted == true && harness.editor.info?.journalKey != nil)
        let key = harness.document.documentKey
        let original = harness.fileBytes

        try harness.highlight("quick brown fox")
        try await harness.save()
        let once = harness.fileBytes
        #expect(once.prefix(original.count) == original)
        #expect(try SavedFile(once, password: v.password).lecternDescriptors.count == 1)
        #expect(try ExternalTool.qpdfCheck(harness.fileURL, password: v.password ?? "").status == 0)
        #expect(!harness.document.isDocumentEdited)
        #expect(!harness.pdf.isLocked)
        #expect(harness.document.documentKey == key)
        #expect(DocumentKey(pdfData: once) == key)

        // A second save onto the already-saved encrypted file.
        try harness.highlight("lazy dog")
        try await harness.save()
        let twice = harness.fileBytes
        #expect(twice.prefix(once.count) == once)
        #expect(try SavedFile(twice, password: v.password).lecternDescriptors.count == 2)
        #expect(try ExternalTool.qpdfCheck(harness.fileURL, password: v.password ?? "").status == 0)
        #expect(harness.document.documentKey == key)
    }

    @Test func undoAndRedoAcrossAnEncryptedSave() async throws {
        let harness = try await AnnotationHarness(corpus: "encrypted-aes256", password: "user-pass")
        defer { harness.close() }
        let note = try harness.highlight("quick brown fox")
        try harness.editor.setContents("Secret comment", of: note)
        try await harness.save()
        #expect(try SavedFile(harness.fileBytes, password: "user-pass").lecternDescriptors.map(\.contents) == ["Secret comment"])
        // Undo the comment: a new change to the saved, encrypted annotation (an edit of its object).
        harness.undo.undo()
        #expect(harness.document.isDocumentEdited)
        try await harness.save()
        #expect(try SavedFile(harness.fileBytes, password: "user-pass").lecternDescriptors.map { $0.contents ?? "" } == [""])
        // Undo the highlight: a delete. Redo puts it back.
        harness.undo.undo()
        try await harness.save()
        #expect(try SavedFile(harness.fileBytes, password: "user-pass").lecternDescriptors.isEmpty)
        harness.undo.redo()
        try await harness.save()
        #expect(try SavedFile(harness.fileBytes, password: "user-pass").lecternDescriptors.count == 1)
    }

    @Test func aReloadUnlocksAgainWithTheSessionPassword() async throws {
        let harness = try await AnnotationHarness(corpus: "encrypted-r4-aes128-objstm", password: "user-pass")
        defer { harness.close() }
        try harness.highlight("quick brown fox")
        try await harness.save()
        // Another app adds a note to the saved file (B7: no unsaved annotations, so it reloads).
        let changed = try IncrementalWriter().saveInPlace(original: harness.fileBytes, changes: [
            .addNote(NewNote(pageIndex: 1, origin: PDFPoint(x: 100, y: 100), contents: "Added elsewhere")),
        ], password: "user-pass").data
        try changed.write(to: harness.fileURL)
        #expect(await harness.document.reloadFromDiskIfChanged())
        #expect(!harness.pdf.isLocked)
        #expect(harness.controller.isShowingContent)
        await harness.waitForInspection()
        #expect(harness.editor.info?.descriptors.contains { $0.contents == "Added elsewhere" } == true)
        // And it saves again.
        try harness.highlight("lazy dog")
        try await harness.save()
        // The first highlight, the other app's note (also written by PDFSave, so it has our /NM
        // prefix) and the new highlight.
        let saved = try SavedFile(harness.fileBytes, password: "user-pass")
        #expect(saved.lecternDescriptors.count == 3)
        #expect(saved.descriptors.contains { $0.contents == "Added elsewhere" })
    }

    @Test func theCrashJournalIsSealedAndRestoresOnceUnlocked() async throws {
        let folder = try TemporaryFolder()
        let url = try folder.write(try Corpus.data("encrypted-aes256"), to: "secret.pdf")
        let first = try await AnnotationHarness(file: url, folder: folder, password: "user-pass")
        let note = try first.highlight("quick brown fox")
        try first.editor.setContents("Confidential remark", of: note)
        let changes = first.editor.pending.changes
        let id = try #require(first.controller.storedDocumentID)
        #expect(first.journal.flush(id))
        let onDisk = String(decoding: try Data(contentsOf: first.journal.url(for: id)), as: UTF8.self)
        #expect(!onDisk.contains("Confidential remark"))
        #expect(!onDisk.contains("lectern-"))
        #expect(!onDisk.contains("Highlight"))
        first.store.flush()
        first.abandon()

        // The next open asks for the password first; the journal is offered only once unlocked.
        let second = try await AnnotationHarness(file: url, folder: folder, store: first.store, journal: first.journal, password: "user-pass")
        defer { second.close() }
        #expect(second.presenter.journalOffers == [changes.count])
        #expect(second.editor.pending.changes == changes)
        try await second.save()
        #expect(try SavedFile(second.fileBytes, password: "user-pass").lecternDescriptors.map(\.contents) == ["Confidential remark"])
    }

    @Test func aSignedEncryptedFileGoesToACopyAndStaysIntact() async throws {
        let harness = try await AnnotationHarness(corpus: "encrypted-signed")
        defer { harness.close() }
        #expect(harness.editor.saveability == .copyOnly([.signed]))
        try harness.highlight("quick brown fox")
        guard case .copy = harness.document.saveRoute else {
            Issue.record("expected the copy route, got \(harness.document.saveRoute)")
            return
        }
        let original = harness.fileBytes
        let copy = harness.folder.url.appending(path: "signed (annotated).pdf")
        try await harness.save(to: copy, .saveAsOperation)
        #expect(harness.fileBytes == original)
        let copyBytes = try Data(contentsOf: copy)
        #expect(copyBytes.prefix(original.count) == original)
        #expect(try SavedFile(copyBytes).lecternDescriptors.count == 1)
        #expect(try ExternalTool.qpdfCheck(copy, password: "").status == 0)
    }

    /// PDFKit can't unlock a non-ASCII password (EncryptionTests in PDFSave), so such a file
    /// can't be opened with it in Lectern, although PDFSave authenticates the same string. The
    /// owner password, if it is ASCII, still opens it. A known limitation.
    @Test func aNonASCIIPasswordDoesntUnlockInPDFKit() async throws {
        let harness = try await AnnotationHarness(corpus: "encrypted-r6-unicode", password: "Grüße-ключ")
        defer { harness.close() }
        #expect(harness.pdf.isLocked)
        #expect(try PDFSaveDocument(data: harness.fileBytes, password: "Grüße-ключ").isEncrypted)
        #expect(harness.controller.submitPassword("owner-pass", remember: false, purpose: .open))
        #expect(!harness.pdf.isLocked)
    }
    // MARK: Review fixes

    /// D3: comment on a saved highlight, save, undo the comment, undo the highlight, ⌘S. The
    /// pending list then holds an edit and a delete of the same object; the save writes their net
    /// effect (the delete) and the undo stack stays whole.
    @Test(arguments: [("classic-xref", nil), ("encrypted-aes256", "user-pass")] as [(String, String?)])
    func undoingACommentAndThenItsSavedHighlightSaves(_ fixture: String, _ password: String?) async throws {
        let harness = try await AnnotationHarness(corpus: fixture, password: password)
        defer { harness.close() }
        let highlight = try harness.highlight("quick brown fox")
        try harness.editor.setContents("A comment", of: highlight)
        try await harness.save()
        #expect(try SavedFile(harness.fileBytes, password: password).lecternDescriptors.map(\.contents) == ["A comment"])
        harness.undo.undo()
        harness.undo.undo()
        #expect(harness.editor.pending.changes.count == 2)
        try await harness.save()
        #expect(try SavedFile(harness.fileBytes, password: password).lecternDescriptors.isEmpty)
        #expect(!harness.document.isDocumentEdited)
        // Undo history is untouched: both steps redo, and that saves too.
        harness.undo.redo()
        harness.undo.redo()
        try await harness.save()
        #expect(try SavedFile(harness.fileBytes, password: password).lecternDescriptors.map(\.contents) == ["A comment"])
    }

    /// D2: a document encrypted with a handler Lectern can't decrypt opens with a quiet notice in
    /// the info line, never an alert (the harness's tripwire fails the test on any UI).
    @Test func aPublicKeyDocumentShowsAQuietNotice() async throws {
        let harness = try await AnnotationHarness(corpus: "encrypted-pubkey")
        defer { harness.close() }
        #expect(harness.editor.saveability == .unsupported(.encrypted(.securityHandler("Adobe.PubSec"))))
        #expect(harness.controller.formInfoLine.message == EncryptionProblem.securityHandler("Adobe.PubSec").openingNotice)
        #expect(harness.controller.formInfoLine.message?.contains("certificates") == true)
        #expect(harness.presenter.refusals.isEmpty)
        #expect(EncryptionProblem.securityHandler("FOO.Custom").openingNotice?.contains("security handler Lectern doesn’t support") == true)
        #expect(EncryptionProblem.revision(version: 5, revision: 5).openingNotice == nil)
    }

    @Test func aReadableEncryptedDocumentHasNoNotice() async throws {
        let harness = try await AnnotationHarness(corpus: "encrypted-r5", password: "user-pass")
        defer { harness.close() }
        #expect(harness.controller.formInfoLine.message == nil)
    }

    /// Item 5: the PDFKit read-back fails on bytes that don't hold what the writer says it wrote,
    /// and on a password that doesn't open them.
    @Test func thePDFKitReadBackCanFail() async throws {
        let data = try Corpus.data("encrypted-aes256")
        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.unlock(withPassword: "user-pass"))
        let selection = try #require(pdf.findString("quick brown fox", withOptions: []).first)
        let page = try #require(selection.pages.first)
        let b = selection.bounds(for: page)
        let change = AnnotationChange.addMarkup(NewMarkup(kind: .highlight, pageIndex: 0, quads: [Quad(rect: PDFRect(x: b.minX, y: b.minY, width: b.width, height: b.height))],
                                                          contents: "Checked by PDFKit"))
        let result = try IncrementalWriter().saveInPlace(original: data, changes: [change], password: "user-pass")
        let descriptors = try SavedFileCheck.verify(result.data, original: data, against: result, password: "user-pass")
        try ReaderDocument.checkWithPDFKit(result.data, against: result, descriptors: descriptors, password: "user-pass")
        #expect(throws: PDFSaveError.verificationFailed("PDFKit can't unlock the saved file")) {
            try ReaderDocument.checkWithPDFKit(result.data, against: result, descriptors: descriptors, password: "wrong")
        }
        #expect(throws: PDFSaveError.verificationFailed("PDFKit doesn’t show the added highlight as written")) {
            try ReaderDocument.checkWithPDFKit(data, against: result, descriptors: descriptors, password: "user-pass")
        }
    }
}

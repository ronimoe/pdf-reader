import Foundation
import PDFKit
import PDFSave
import ReaderCore
import Testing
@testable import Persistence

/// The crash journal of an encrypted document (M7, architecture §6), and the identity that
/// keys it and the Keychain password: neither may change when such a document is saved.
@Suite struct EncryptedJournalTests {
    static let corpus: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url.appending(path: "Tests/Corpus/public")
    }()

    let folder = FileManager.default.temporaryDirectory.appending(path: "LecternEncryptedJournal-\(UUID().uuidString)", directoryHint: .isDirectory)
    let secret = "Confidential remark about the merger"
    var changes: [AnnotationChange] {
        [.addNote(NewNote(pageIndex: 0, origin: PDFPoint(x: 10, y: 10), contents: secret, author: "Ann Author", name: "lectern-secret")),
         .editContents(ObjectRef(7), "Another secret")]
    }

    func journalKey(_ name: String, password: String?) throws -> (JournalKey, Data) {
        let data = try Data(contentsOf: Self.corpus.appending(path: "\(name).pdf"))
        let fileKey = try #require(try PDFSaveDocument(data: data, password: password).fileEncryptionKey)
        return (JournalKey(fileKey: fileKey, documentKey: DocumentKey(pdfData: data)), data)
    }

    @Test func aSealedJournalHoldsNoPlainText() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = AnnotationJournal(directory: folder, debounce: .seconds(60))
        let (key, data) = try journalKey("encrypted-aes256", password: "user-pass")
        let id = UUID()
        let hash = JournalEntry.hash(of: data)
        journal.record(JournalEntry(originalSHA256: hash, changes: changes), for: id, sealedWith: key)
        #expect(journal.flush(id))
        let onDisk = try Data(contentsOf: journal.url(for: id))
        let text = String(decoding: onDisk, as: UTF8.self)
        for needle in [secret, "Another secret", "Ann Author", "lectern-secret", "addNote"] {
            #expect(!text.contains(needle), "\(needle) is in the clear")
        }
        // The metadata stays readable: the hash, so it can be matched without the key.
        #expect(text.contains(hash))
        guard case .matching(let entry) = journal.lookup(id, currentSHA256: hash, key: key) else {
            Issue.record("the key didn't open it"); return
        }
        #expect(entry.changes == changes)
    }

    @Test func theUserAndTheOwnerPasswordGiveTheSameKey() throws {
        let (user, data) = try journalKey("encrypted-r4-aes128-objstm", password: "user-pass")
        let (owner, _) = try journalKey("encrypted-r4-aes128-objstm", password: "owner-pass")
        let sealed = try JournalEntry(originalSHA256: JournalEntry.hash(of: data), changes: changes).sealed(with: user)
        #expect(try sealed.opened(with: owner).changes == changes)
    }

    @Test func aJournalThatDoesntOpenIsKeptAndExplainedNeverDeleted() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = AnnotationJournal(directory: folder, debounce: .seconds(60))
        let (key, data) = try journalKey("encrypted-aes256", password: "user-pass")
        let (otherKey, _) = try journalKey("encrypted-r6-objstm-restricted", password: nil)
        let id = UUID()
        let hash = JournalEntry.hash(of: data)
        journal.record(JournalEntry(originalSHA256: hash, changes: changes), for: id, sealedWith: key)
        journal.flush(id)
        // Without a key (still locked), or with another file's key: unreadable, and still there.
        #expect(journal.lookup(id, currentSHA256: hash) == .unreadable)
        #expect(journal.lookup(id, currentSHA256: hash, key: otherKey) == .unreadable)
        #expect(FileManager.default.fileExists(atPath: journal.url(for: id).path))
        // For other bytes: a mismatch, as for a plain journal, with nothing opened.
        guard case .mismatched(let entry) = journal.lookup(id, currentSHA256: "other", key: key) else {
            Issue.record("expected a mismatch"); return
        }
        #expect(entry.changes.isEmpty && entry.isSealed)
        // Set aside, it is still offered, and still opens with the right key.
        let kept = try #require(journal.setAside(id))
        #expect(journal.read(kept, currentSHA256: hash, key: key) == .matching(JournalEntry(originalSHA256: hash, changes: changes, written: entry.written)))
    }

    @Test func aSealedPayloadCantBeMovedToAnotherFilesEntry() throws {
        let (key, data) = try journalKey("encrypted-aes256", password: "user-pass")
        var sealed = try JournalEntry(originalSHA256: JournalEntry.hash(of: data), changes: changes).sealed(with: key)
        sealed.originalSHA256 = JournalEntry.hash(of: Data("another version".utf8))
        #expect(throws: (any Error).self) { try sealed.opened(with: key) }
    }

    @Test func anEmptyChangeListStillDeletesTheJournal() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = AnnotationJournal(directory: folder, debounce: .seconds(60))
        let (key, data) = try journalKey("encrypted-aes256", password: "user-pass")
        let id = UUID()
        let hash = JournalEntry.hash(of: data)
        journal.record(JournalEntry(originalSHA256: hash, changes: changes), for: id, sealedWith: key)
        journal.flush(id)
        journal.record(JournalEntry(originalSHA256: hash, changes: []), for: id, sealedWith: key)
        journal.flush(id)
        #expect(!FileManager.default.fileExists(atPath: journal.url(for: id).path))
    }

    @Test func plainJournalsFromBeforeStillRead() throws {
        // A journal written before sealing existed has no "sealed" key.
        let json = #"{"changes":[{"delete":{"_0":{"generation":2,"number":8}}}],"originalSHA256":"aa","written":"2026-10-29T10:00:00Z"}"#
        let entry = try JSONDecoder.journal.decode(JournalEntry.self, from: Data(json.utf8))
        #expect(entry.changes == [.delete(ObjectRef(8, 2))])
        #expect(!entry.isSealed)
    }

    // MARK: Identity across a save

    /// The Keychain password, reading positions and bookmarks follow `DocumentKey`: an encrypted
    /// save must leave it exactly as it was, for every supported variant, and so must a second save.
    @Test(arguments: [
        ("encrypted-r2-rc4-40", "user-pass"), ("encrypted-r3-rc4-annotated", nil), ("encrypted-r4-rc4", "pässwörd"),
        ("encrypted-r4-aes128-objstm", "user-pass"), ("encrypted-r4-cleartext-metadata", nil), ("encrypted-r4-identity-strings", nil),
        ("encrypted-aes256", "user-pass"), ("encrypted-r6-objstm-restricted", nil), ("encrypted-r6-unicode", "Grüße-ключ"),
    ] as [(String, String?)])
    func theDocumentKeyIsTheSameAfterAnEncryptedSave(_ name: String, _ password: String?) throws {
        let original = try Data(contentsOf: Self.corpus.appending(path: "\(name).pdf"))
        let note = AnnotationChange.addNote(NewNote(pageIndex: 0, origin: PDFPoint(x: 40, y: 40), contents: "Kept with its key"))
        let once = try IncrementalWriter().saveInPlace(original: original, changes: [note], password: password).data
        let again = try IncrementalWriter().saveInPlace(original: once, changes: [
            .addNote(NewNote(pageIndex: 0, origin: PDFPoint(x: 80, y: 40), contents: "Second save")),
        ], password: password).data
        let key = DocumentKey(pdfData: original)
        #expect(key.rawValue.contains(";enc:"), "\(key)")
        #expect(DocumentKey(pdfData: once) == key)
        #expect(DocumentKey(pdfData: again) == key)
        // And the journal key with it.
        let fileKey = try #require(try PDFSaveDocument(data: again, password: password).fileEncryptionKey)
        let sealed = try JournalEntry(originalSHA256: "x", changes: [note]).sealed(with: JournalKey(fileKey: fileKey, documentKey: DocumentKey(pdfData: once)))
        let originalKey = try #require(try PDFSaveDocument(data: original, password: password).fileEncryptionKey)
        #expect(try sealed.opened(with: JournalKey(fileKey: originalKey, documentKey: key)).changes == [note])
    }
}

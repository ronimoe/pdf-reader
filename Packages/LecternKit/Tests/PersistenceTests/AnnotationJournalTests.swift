import Foundation
import PDFSave
import Testing
@testable import Persistence

/// The crash journal (A1, architecture §6), against temporary folders.
@Suite struct AnnotationJournalTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "LecternJournalTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    let changes: [AnnotationChange] = [
        .addMarkup(NewMarkup(kind: .highlight, pageIndex: 0, quads: [Quad(rect: PDFRect(x: 1, y: 2, width: 3, height: 4))], contents: "é", name: "lectern-x")),
        .editColor(ObjectRef(7), PDFRGBColor(red: 0, green: 1, blue: 0)),
        .delete(ObjectRef(8, 2)),
    ]

    func journal(debounce: Duration = .milliseconds(20)) -> AnnotationJournal {
        AnnotationJournal(directory: folder.appending(path: "Journal", directoryHint: .isDirectory), debounce: debounce)
    }

    @Test func writesAfterTheDebounceAndReadsBack() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = journal()
        let id = UUID()
        let hash = JournalEntry.hash(of: Data("original".utf8))
        journal.record(JournalEntry(originalSHA256: hash, changes: changes), for: id)
        try await Task.sleep(for: .milliseconds(300))
        guard case .matching(let entry) = journal.lookup(id, currentSHA256: hash) else {
            Issue.record("expected a matching entry")
            return
        }
        #expect(entry.changes == changes)
        #expect(journal.url(for: id).lastPathComponent == "\(id.uuidString).json")
        #expect(journal.url(for: id).deletingLastPathComponent().lastPathComponent == "Journal")
    }

    @Test func aDifferentHashIsAMismatch() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = journal(debounce: .seconds(60))
        let id = UUID()
        journal.record(JournalEntry(originalSHA256: "aa", changes: changes), for: id)
        journal.flush(id)
        guard case .mismatched(let entry) = journal.lookup(id, currentSHA256: "bb") else {
            Issue.record("expected a mismatch")
            return
        }
        #expect(entry.changes == changes)
        // A mismatch never deletes the file by itself.
        #expect(FileManager.default.fileExists(atPath: journal.url(for: id).path))
    }

    @Test func onlyTheLatestOfSeveralQuickChangesIsWritten() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = journal(debounce: .seconds(60))
        let id = UUID()
        journal.record(JournalEntry(originalSHA256: "h", changes: [changes[0]]), for: id)
        journal.record(JournalEntry(originalSHA256: "h", changes: changes), for: id)
        #expect(journal.lookup(id, currentSHA256: "h") == .none)
        journal.flush(id)
        guard case .matching(let entry) = journal.lookup(id, currentSHA256: "h") else {
            Issue.record("expected a matching entry")
            return
        }
        #expect(entry.changes == changes)
    }

    @Test func removeDeletesAndCancelsAScheduledWrite() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = journal(debounce: .milliseconds(50))
        let id = UUID()
        journal.record(JournalEntry(originalSHA256: "h", changes: changes), for: id)
        journal.flush(id)
        #expect(FileManager.default.fileExists(atPath: journal.url(for: id).path))
        journal.record(JournalEntry(originalSHA256: "h", changes: [changes[1]]), for: id)
        journal.remove(id)
        try await Task.sleep(for: .milliseconds(300))
        #expect(journal.lookup(id, currentSHA256: "h") == .none)
    }

    @Test func anEmptyListDeletesTheFile() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = journal(debounce: .seconds(60))
        let id = UUID()
        journal.record(JournalEntry(originalSHA256: "h", changes: changes), for: id)
        journal.flush(id)
        journal.record(JournalEntry(originalSHA256: "h", changes: []), for: id)
        journal.flush(id)
        #expect(journal.lookup(id, currentSHA256: "h") == .none)
    }

    @Test func anUnreadableFileIsReportedNotDeleted() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = journal()
        let id = UUID()
        try FileManager.default.createDirectory(at: journal.directory, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: journal.url(for: id))
        #expect(journal.lookup(id, currentSHA256: "h") == .unreadable)
        #expect(FileManager.default.fileExists(atPath: journal.url(for: id).path))
    }

    @Test func hashIsSHA256Hex() {
        #expect(JournalEntry.hash(of: Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

import CryptoKit
import Foundation
import os
import PDFSave
import Synchronization

/// One document's unsaved annotation changes, as journaled for crash recovery (A1).
public struct JournalEntry: Codable, Equatable, Sendable {
    /// SHA-256 of the bytes the changes apply to, as lowercase hex. `ObjectRef`s in the changes
    /// only mean something for exactly these bytes.
    public var originalSHA256: String
    public var changes: [AnnotationChange]
    public var written: Date

    public init(originalSHA256: String, changes: [AnnotationChange], written: Date = Date()) {
        self.originalSHA256 = originalSHA256
        self.changes = changes
        self.written = written
    }

    /// The hex SHA-256 of `data`.
    public static func hash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// What a document finds in the journal when it opens.
public enum JournalLookup: Equatable, Sendable {
    case none
    /// Unsaved changes for exactly these bytes: offer Restore or Discard.
    case matching(JournalEntry)
    /// Changes for other bytes (the file changed since): explain, and offer Discard.
    case mismatched(JournalEntry)
    /// A journal file that can't be read. Treated like a mismatch: explained, never deleted
    /// silently.
    case unreadable
}

/// The crash journal (A1, architecture §6): `Journal/<uuid>.json`, one file per document with
/// unsaved annotations, keyed by the document's stored-state UUID.
///
/// Writes are debounced and atomic, on a private queue. A file is deleted after a successful save
/// or when the user discards the changes. The directory is injected, so tests use temporary
/// folders.
public final class AnnotationJournal: Sendable {
    public let directory: URL
    private let debounce: Duration
    private let queue = DispatchQueue(label: "io.github.ronimoe.Lectern.AnnotationJournal")
    private let pending = Mutex<[UUID: Scheduled]>([:])

    private struct Scheduled: Sendable {
        var entry: JournalEntry?
        var generation: Int
        /// The write for this generation already happened.
        var isDone = false
    }
    private static let log = Logger(subsystem: "io.github.ronimoe.Lectern", category: "AnnotationJournal")

    public init(directory: URL, debounce: Duration = .milliseconds(500)) {
        self.directory = directory
        self.debounce = debounce
    }

    public func url(for id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).json")
    }

    /// Schedules `entry` to be written after the debounce. A later call for the same document
    /// replaces it; an empty change list deletes the file instead.
    public func record(_ entry: JournalEntry, for id: UUID) {
        let generation = pending.withLock { state -> Int in
            let next = (state[id]?.generation ?? 0) + 1
            state[id] = Scheduled(entry: entry.changes.isEmpty ? nil : entry, generation: next)
            return next
        }
        let parts = debounce.components
        let nanoseconds = Int(parts.seconds) * 1_000_000_000 + Int(parts.attoseconds / 1_000_000_000)
        queue.asyncAfter(deadline: .now() + .nanoseconds(nanoseconds)) { [self] in
            writeIfCurrent(id, generation: generation)
        }
    }

    /// Writes any scheduled entry for `id` now, and waits for it.
    public func flush(_ id: UUID) {
        queue.sync {
            let current = pending.withLock { $0[id]?.generation ?? 0 }
            writeIfCurrent(id, generation: current)
        }
    }

    /// Deletes the journal for `id`, cancelling any scheduled write.
    public func remove(_ id: UUID) {
        pending.withLock { state in
            let next = (state[id]?.generation ?? 0) + 1
            state[id] = Scheduled(entry: nil, generation: next)
        }
        queue.sync {
            try? FileManager.default.removeItem(at: url(for: id))
        }
    }

    /// What the journal holds for `id`, compared with the hash of the bytes that are open now.
    public func lookup(_ id: UUID, currentSHA256: String) -> JournalLookup {
        let file = url(for: id)
        guard FileManager.default.fileExists(atPath: file.path) else { return .none }
        guard let data = try? Data(contentsOf: file),
              let entry = try? JSONDecoder.journal.decode(JournalEntry.self, from: data)
        else { return .unreadable }
        return entry.originalSHA256 == currentSHA256 ? .matching(entry) : .mismatched(entry)
    }

    private func writeIfCurrent(_ id: UUID, generation: Int) {
        let scheduled = pending.withLock { state -> Scheduled? in
            guard var current = state[id], current.generation == generation, !current.isDone else { return nil }
            // The generation stays, so a write queued earlier can never match a later one.
            current.isDone = true
            state[id] = current
            return current
        }
        guard let scheduled else { return }
        let file = url(for: id)
        guard let entry = scheduled.entry else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder.journal.encode(entry)
            try data.write(to: file, options: .atomic)
        } catch {
            Self.log.error("Couldn't write the annotation journal: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension JSONEncoder {
    static var journal: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var journal: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

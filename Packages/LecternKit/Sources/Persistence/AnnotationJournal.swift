import CryptoKit
import Foundation
import os
import PDFSave
import ReaderCore
import Synchronization

/// One document's unsaved annotation changes, as journaled for crash recovery (A1).
public struct JournalEntry: Codable, Equatable, Sendable {
    /// SHA-256 of the bytes the changes apply to, as lowercase hex. `ObjectRef`s in the changes
    /// only mean something for exactly these bytes.
    public var originalSHA256: String
    /// Empty in a sealed entry: the changes are in `sealed`.
    public var changes: [AnnotationChange]
    public var written: Date
    /// An encrypted document's changes, sealed with AES-GCM under its `JournalKey` (nonce,
    /// ciphertext and tag together), so its notes never sit on disk in plain text. The hash and
    /// the date stay readable, so the journal can be matched and explained without the key.
    public var sealed: Data?

    public init(originalSHA256: String, changes: [AnnotationChange], written: Date = Date()) {
        self.originalSHA256 = originalSHA256
        self.changes = changes
        self.written = written
    }

    /// The hex SHA-256 of `data`.
    public static func hash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public var isSealed: Bool { sealed != nil }

    /// This entry with its changes sealed under `key`. The hash is authenticated with them, so a
    /// sealed payload can't be moved onto another file's entry.
    public func sealed(with key: JournalKey) throws -> JournalEntry {
        let plain = try JSONEncoder.journal.encode(changes)
        let box = try AES.GCM.seal(plain, using: key.key, authenticating: Data(originalSHA256.utf8))
        guard let combined = box.combined else { throw CryptoKitError.incorrectParameterSize }
        var entry = JournalEntry(originalSHA256: originalSHA256, changes: [], written: written)
        entry.sealed = combined
        return entry
    }

    /// The changes of a sealed entry, opened with `key`. Throws for a wrong key or a damaged payload.
    public func opened(with key: JournalKey) throws -> JournalEntry {
        guard let sealed else { return self }
        let box = try AES.GCM.SealedBox(combined: sealed)
        let plain = try AES.GCM.open(box, using: key.key, authenticating: Data(originalSHA256.utf8))
        return JournalEntry(originalSHA256: originalSHA256, changes: try JSONDecoder.journal.decode([AnnotationChange].self, from: plain),
                            written: written)
    }
}

/// The key an encrypted document's journal is sealed with (architecture §6): HKDF-SHA256 of the
/// PDF's file encryption key, salted with the SHA-256 of its encryption dictionary's `/O` and `/U`
/// (`PDFSaveDocument.encryptionDigest`), under a fixed Lectern info string. The salt lives exactly
/// as long as the file key: a save keeps both, with or without an `/ID` (M7 review; an earlier
/// `DocumentKey` salt changed on every save of a file without `/ID`). It exists only in memory, and
/// only once the document is unlocked; the file key is the same whichever password opened it, so
/// the user and the owner password give the same key.
public struct JournalKey: Sendable {
    static let info = Data("io.github.ronimoe.Lectern annotation journal v1".utf8)
    let key: SymmetricKey

    public init(fileKey: Data, encryptionDigest: Data) {
        key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: fileKey), salt: encryptionDigest,
                                     info: Self.info, outputByteCount: 32)
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

/// One journal file and what it holds, so the app acts on exactly the file it offered.
public struct JournalFile: Equatable, Sendable {
    public let url: URL
    public let lookup: JournalLookup

    public init(url: URL, lookup: JournalLookup) {
        self.url = url
        self.lookup = lookup
    }

    /// A journal set aside earlier (`<uuid>.kept-<time>.json`) rather than the live one.
    public var isKept: Bool { url.lastPathComponent.contains(".kept-") }
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
        /// That write failed.
        var failed = false
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
    /// replaces it; an empty change list deletes the file instead. With `key` (an encrypted
    /// document), the changes are sealed before they are queued; if that fails nothing is written,
    /// never the plain text.
    public func record(_ entry: JournalEntry, for id: UUID, sealedWith key: JournalKey? = nil) {
        var entry = entry
        if let key, !entry.changes.isEmpty {
            do {
                entry = try entry.sealed(with: key)
            } catch {
                Self.log.error("Couldn't seal the annotation journal: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
        let generation = pending.withLock { state -> Int in
            let next = (state[id]?.generation ?? 0) + 1
            state[id] = Scheduled(entry: entry.changes.isEmpty && !entry.isSealed ? nil : entry, generation: next)
            return next
        }
        let parts = debounce.components
        let nanoseconds = Int(parts.seconds) * 1_000_000_000 + Int(parts.attoseconds / 1_000_000_000)
        queue.asyncAfter(deadline: .now() + .nanoseconds(nanoseconds)) { [self] in
            writeIfCurrent(id, generation: generation)
        }
    }

    /// Writes any scheduled entry for `id` now, and waits for it.
    /// Returns whether the live journal now holds the latest recorded changes (true when there
    /// was nothing to write).
    @discardableResult
    public func flush(_ id: UUID) -> Bool {
        queue.sync {
            let current = pending.withLock { $0[id]?.generation ?? 0 }
            writeIfCurrent(id, generation: current)
            return pending.withLock { !($0[id]?.failed ?? false) }
        }
    }

    /// Deletes the live journal for `id` (after a save, a reload, or Don't Save), cancelling any
    /// scheduled write. Journals the user chose to keep are left alone.
    public func remove(_ id: UUID) {
        pending.withLock { state in
            let next = (state[id]?.generation ?? 0) + 1
            state[id] = Scheduled(entry: nil, generation: next)
        }
        queue.sync {
            try? FileManager.default.removeItem(at: url(for: id))
        }
    }

    /// Deletes exactly one journal file: the one the user was shown and chose to discard, or
    /// one whose changes are live again. Other journals, kept or live, are never touched.
    public func delete(_ file: JournalFile) {
        guard file.url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else { return }
        queue.sync { try? FileManager.default.removeItem(at: file.url) }
    }

    /// Moves the live journal aside, out of the way of the document's new changes: nothing
    /// written, saved or closed later replaces or deletes it, and it is offered again the next
    /// time the document opens. Returns the kept file, or nil if there was no live journal.
    @discardableResult
    public func setAside(_ id: UUID, now: Date = Date()) -> URL? {
        flush(id)
        return queue.sync { () -> URL? in
            let live = url(for: id)
            guard FileManager.default.fileExists(atPath: live.path) else { return nil }
            var stamp = Int(now.timeIntervalSince1970 * 1000)
            var kept = directory.appending(path: "\(id.uuidString).kept-\(stamp).json")
            while FileManager.default.fileExists(atPath: kept.path) {
                stamp += 1
                kept = directory.appending(path: "\(id.uuidString).kept-\(stamp).json")
            }
            return (try? FileManager.default.moveItem(at: live, to: kept)) != nil ? kept : nil
        }
    }

    /// Kept journals for `id`, oldest first.
    func keptFiles(for id: UUID) -> [URL] {
        let prefix = "\(id.uuidString).kept-"
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The journal to offer for `id`: the live one if there is one, otherwise the oldest kept one,
    /// with what it holds compared with the hash of the bytes that are open now. `key` opens a
    /// sealed journal (see `read`).
    public func find(_ id: UUID, currentSHA256: String, key: JournalKey? = nil) -> JournalFile? {
        let live = url(for: id)
        let file: URL
        if FileManager.default.fileExists(atPath: live.path) {
            file = live
        } else if let kept = keptFiles(for: id).first {
            file = kept
        } else {
            return nil
        }
        return JournalFile(url: file, lookup: read(file, currentSHA256: currentSHA256, key: key))
    }

    /// What one journal file holds, compared with `currentSHA256`. A sealed journal for these
    /// bytes is opened with `key`; without the key, or when it doesn't open, it is `.unreadable`,
    /// which the app explains and keeps unless the user discards it. A sealed journal for other
    /// bytes is `.mismatched` with its changes still sealed.
    public func read(_ file: URL, currentSHA256: String, key: JournalKey? = nil) -> JournalLookup {
        guard FileManager.default.fileExists(atPath: file.path) else { return .none }
        guard let data = try? Data(contentsOf: file),
              let entry = try? JSONDecoder.journal.decode(JournalEntry.self, from: data)
        else { return .unreadable }
        guard entry.originalSHA256 == currentSHA256 else { return .mismatched(entry) }
        guard entry.isSealed else { return .matching(entry) }
        guard let key, let opened = try? entry.opened(with: key) else { return .unreadable }
        return .matching(opened)
    }

    /// What `find` would offer for `id`.
    public func lookup(_ id: UUID, currentSHA256: String, key: JournalKey? = nil) -> JournalLookup {
        find(id, currentSHA256: currentSHA256, key: key)?.lookup ?? .none
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
            pending.withLock { state in
                if state[id]?.generation == generation { state[id]?.failed = true }
            }
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

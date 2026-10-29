import Foundation
import os
import ReaderCore
import Synchronization

/// Makes and resolves file bookmarks. The app uses security-scoped ones;
/// tests can substitute their own.
public protocol FileBookmarking: Sendable {
    func bookmarkData(for url: URL) -> Data?
    /// Where the bookmark points now, or nil if it no longer resolves to an
    /// existing file.
    func resolve(_ data: Data) -> URL?
}

/// Security-scoped bookmarks, which survive relaunches inside the sandbox and
/// follow moves and renames (architecture §6, spikes/m0c-platform.md §1).
public struct SecurityScopedBookmarks: FileBookmarking {
    public init() {}

    public func bookmarkData(for url: URL) -> Data? {
        if let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            return data
        }
        // Outside the sandbox (command-line tests) a plain bookmark does the same job.
        return try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    public func resolve(_ data: Data) -> URL? {
        var isStale = false
        let url = (try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &isStale))
            ?? (try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &isStale))
        guard let url else { return nil }
        // A stale bookmark is replaced the next time the document opens,
        // because `open` always records a fresh one.
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// A document's stored state, as found when it opened.
public struct StoredDocument: Sendable {
    public let id: UUID
    public let state: DocumentState
    public let match: DocumentMatcher.Match
}

/// Per-document state on disk (A2, architecture §6): one JSON file per
/// document in `Documents/<uuid>.json`, and `index.json` mapping identities
/// to those UUIDs.
///
/// Changes are kept in memory and written atomically after a debounce, on a
/// private queue. State files are written before the index, so the index
/// never names a record that isn't on disk; a failed write is retried.
/// `flush()` writes everything now; call it when a document closes and when
/// the app quits. The root directory is injected, so tests never touch the
/// app's container.
///
/// The index is the only list of what was opened, so it is never thrown
/// away: an index that can't be read is moved aside and rebuilt from the
/// state files. Records are pruned after `maximumAge` without being opened,
/// and beyond `maximumDocuments`, because each keeps a path and a bookmark.
public final class DocumentStateStore: Sendable {
    public let directory: URL
    private let bookmarks: any FileBookmarking
    private let debounce: Duration
    private let retryDelay: Duration
    public let maximumDocuments: Int
    public let maximumAge: TimeInterval
    private let queue = DispatchQueue(label: "io.github.ronimoe.Lectern.DocumentStateStore")
    private let shared = Mutex(Shared())
    private static let log = Logger(subsystem: "io.github.ronimoe.Lectern", category: "DocumentStateStore")

    public static let defaultMaximumDocuments = 500
    public static let defaultMaximumAge: TimeInterval = 180 * 24 * 60 * 60

    private struct Shared: Sendable {
        var index: [UUID: IndexEntry]?
        var states: [UUID: DocumentState] = [:]
        var dirty: Set<UUID> = []
        /// Records whose state file is to be deleted.
        var removed: Set<UUID> = []
        var indexIsDirty = false
        var writeIsScheduled = false
    }

    struct IndexEntry: Codable, Hashable, Sendable {
        var identity: DocumentIdentity
        var lastOpened: Date
    }

    private struct IndexFile: Codable {
        var version = 1
        var documents: [String: IndexEntry]
    }

    public init(
        directory: URL,
        bookmarks: any FileBookmarking = SecurityScopedBookmarks(),
        debounce: Duration = .seconds(1),
        retryDelay: Duration = .seconds(5),
        maximumDocuments: Int = DocumentStateStore.defaultMaximumDocuments,
        maximumAge: TimeInterval = DocumentStateStore.defaultMaximumAge
    ) {
        self.directory = directory
        self.bookmarks = bookmarks
        self.debounce = debounce
        self.retryDelay = retryDelay
        self.maximumDocuments = max(1, maximumDocuments)
        self.maximumAge = maximumAge
    }

    /// `Application Support/<bundle id>`, inside the sandbox container when
    /// sandboxed.
    public static func defaultDirectory(bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "io.github.ronimoe.Lectern") -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appending(path: bundleIdentifier, directoryHint: .isDirectory)
    }

    var indexURL: URL { directory.appending(path: "index.json") }
    var documentsDirectory: URL { directory.appending(path: "Documents", directoryHint: .isDirectory) }

    func stateURL(for id: UUID) -> URL {
        documentsDirectory.appending(path: "\(id.uuidString).json")
    }

    /// The records on file.
    public var storedDocumentIDs: Set<UUID> { Set(loadedIndex().keys) }

    // MARK: Opening

    /// The identity of the file at `url` with contents `data`. Pass the
    /// `/ID` pair when the caller already has it, so the file isn't parsed
    /// again.
    public func identity(for url: URL, data: Data, pageCount: Int, fileIdentifiers: [String]? = nil) -> DocumentIdentity {
        DocumentIdentity(
            bookmark: bookmarks.bookmarkData(for: url),
            fileIdentifiers: fileIdentifiers ?? DocumentIdentity.fileIdentifiers(ofPDF: data),
            pageCount: pageCount,
            fileSize: data.count,
            lastKnownPath: Self.path(of: url),
            fingerprint: DocumentIdentity.fingerprint(of: data),
            fileNumber: DocumentIdentity.fileNumber(of: url)
        )
    }

    /// Finds the stored state for the file that is opening, or starts a new
    /// record (A2). The record's identity is refreshed, including a new
    /// bookmark, so a stale one is replaced. Old records are pruned.
    @discardableResult
    public func open(url: URL, data: Data, pageCount: Int, fileIdentifiers: [String]? = nil, now: Date = Date()) -> StoredDocument {
        let identity = identity(for: url, data: data, pageCount: pageCount, fileIdentifiers: fileIdentifiers)
        let path = identity.lastKnownPath
        let index = loadedIndex()

        // Only records that could be this file are resolved: same path, same
        // file number (renamed or moved), same /ID, or the same content.
        let candidates = index.compactMap { id, entry -> DocumentMatcher.Candidate? in
            let stored = entry.identity
            let related = stored.lastKnownPath == path
                || (identity.fileNumber != nil && stored.fileNumber == identity.fileNumber)
                || (identity.permanentIdentifier != nil && stored.permanentIdentifier == identity.permanentIdentifier)
                || stored.fingerprint == identity.fingerprint
            guard related else { return nil }
            let resolved = stored.bookmark.flatMap(bookmarks.resolve).map(Self.path(of:))
            return DocumentMatcher.Candidate(id: id, identity: stored, lastOpened: entry.lastOpened, resolvedPath: resolved)
        }
        let match = DocumentMatcher.match(path: path, identity: identity, candidates: candidates)

        let id: UUID
        var state: DocumentState
        switch match {
        case .same(let existing, let contentChanged):
            id = existing
            state = loadedState(for: existing) ?? DocumentState(identity: identity)
            if contentChanged { state = state.clamped(toPageCount: pageCount) }
        case .duplicate(let original):
            id = UUID()
            state = loadedState(for: original) ?? DocumentState(identity: identity)
        case .new:
            id = UUID()
            state = DocumentState(identity: identity)
        }
        state.identity = identity
        state.lastOpened = now
        let stored = state
        save(stored, for: id)
        prune(now: now)
        return StoredDocument(id: id, state: stored, match: match)
    }

    // MARK: Reading and changing

    public func state(for id: UUID) -> DocumentState? {
        loadedState(for: id)
    }

    /// Changes a document's state. The write happens after the debounce.
    /// A record that was forgotten or pruned stays gone.
    public func update(_ id: UUID, _ change: (inout DocumentState) -> Void) {
        guard loadedIndex()[id] != nil, var state = loadedState(for: id) else { return }
        change(&state)
        save(state, for: id)
    }

    /// Writes every pending change now, on the caller's thread's behalf.
    public func flush() {
        queue.sync { writePending() }
    }

    // MARK: Forgetting (privacy)

    /// Drops records not opened within `maximumAge` of `now`, and the oldest
    /// beyond `maximumDocuments`.
    public func prune(now: Date = Date()) {
        let newestFirst = loadedIndex().sorted { $0.value.lastOpened > $1.value.lastOpened }
        var doomed = Set<UUID>()
        for (position, (id, entry)) in newestFirst.enumerated()
        where position >= maximumDocuments || now.timeIntervalSince(entry.lastOpened) > maximumAge {
            doomed.insert(id)
        }
        remove(doomed)
    }

    /// Forgets everything stored for these files: positions, history,
    /// settings, paths and bookmarks. Used when the user clears Open Recent.
    public func forget(fileURLs urls: [URL]) {
        let paths = Set(urls.map(Self.path(of:)))
        guard !paths.isEmpty else { return }
        let doomed = Set(loadedIndex().compactMap { id, entry -> UUID? in
            if paths.contains(entry.identity.lastKnownPath) { return id }
            if let resolved = entry.identity.bookmark.flatMap(bookmarks.resolve), paths.contains(Self.path(of: resolved)) {
                return id
            }
            return nil
        })
        remove(doomed)
    }

    private func remove(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        shared.withLock { shared in
            for id in ids {
                shared.index?[id] = nil
                shared.states[id] = nil
                shared.dirty.remove(id)
                shared.removed.insert(id)
            }
            shared.indexIsDirty = true
        }
        scheduleWrite(after: debounce)
    }

    // MARK: Internals

    private func save(_ state: DocumentState, for id: UUID) {
        _ = loadedIndex()
        let changed = shared.withLock { shared -> Bool in
            guard shared.states[id] != state else { return false }
            shared.states[id] = state
            shared.dirty.insert(id)
            shared.removed.remove(id)
            let entry = IndexEntry(identity: state.identity, lastOpened: state.lastOpened)
            if shared.index?[id] != entry {
                shared.index?[id] = entry
                shared.indexIsDirty = true
            }
            return true
        }
        if changed { scheduleWrite(after: debounce) }
    }

    private func scheduleWrite(after delay: Duration) {
        let shouldSchedule = shared.withLock { shared -> Bool in
            guard !shared.writeIsScheduled else { return false }
            shared.writeIsScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        let components = delay.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.writePending()
        }
    }

    /// The index, read once. A missing index is rebuilt from the state files
    /// (normally there are none); one that can't be read or decoded is moved
    /// aside first, so nothing on record is lost.
    private func loadedIndex() -> [UUID: IndexEntry] {
        if let index = shared.withLock({ $0.index }) { return index }
        var loaded: [UUID: IndexEntry] = [:]
        var needsWriting = false
        do {
            let data = try Data(contentsOf: indexURL)
            let file = try Self.decoder.decode(IndexFile.self, from: data)
            for (key, entry) in file.documents {
                if let id = UUID(uuidString: key) { loaded[id] = entry }
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            loaded = rebuiltIndex()
            needsWriting = !loaded.isEmpty
        } catch {
            Self.log.error("index.json is unreadable and is rebuilt from the state files: \(error.localizedDescription, privacy: .public)")
            moveAsideUnreadableIndex()
            loaded = rebuiltIndex()
            needsWriting = true
        }
        let result = shared.withLock { shared -> [UUID: IndexEntry] in
            if let index = shared.index { return index }
            shared.index = loaded
            if needsWriting { shared.indexIsDirty = true }
            return loaded
        }
        if needsWriting { scheduleWrite(after: debounce) }
        return result
    }

    /// Every readable state file's identity and last-opened date.
    private func rebuiltIndex() -> [UUID: IndexEntry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: documentsDirectory, includingPropertiesForKeys: nil)) ?? []
        var index: [UUID: IndexEntry] = [:]
        for file in files where file.pathExtension == "json" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  let data = try? Data(contentsOf: file),
                  let state = try? Self.decoder.decode(DocumentState.self, from: data)
            else { continue }
            index[id] = IndexEntry(identity: state.identity, lastOpened: state.lastOpened)
        }
        return index
    }

    private func moveAsideUnreadableIndex() {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return }
        let aside = directory.appending(path: "index.unreadable-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.moveItem(at: indexURL, to: aside)
    }

    private func loadedState(for id: UUID) -> DocumentState? {
        if let state = shared.withLock({ $0.states[id] }) { return state }
        guard let data = try? Data(contentsOf: stateURL(for: id)) else { return nil }
        do {
            let state = try Self.decoder.decode(DocumentState.self, from: data)
            return shared.withLock { shared in
                if let newer = shared.states[id] { return newer }
                shared.states[id] = state
                return state
            }
        } catch {
            Self.log.error("State file \(id.uuidString, privacy: .public) is unreadable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Runs on `queue` only, so writes never interleave. State files go
    /// first and the index last; if any state file fails, the index waits
    /// too, and everything that failed is tried again later.
    private func writePending() {
        let (states, removed, index) = shared.withLock { shared -> ([UUID: DocumentState], Set<UUID>, [UUID: IndexEntry]?) in
            let states = shared.dirty.reduce(into: [UUID: DocumentState]()) { result, id in result[id] = shared.states[id] }
            let removed = shared.removed
            shared.dirty.removeAll()
            shared.removed.removeAll()
            let index = shared.indexIsDirty ? shared.index : nil
            shared.indexIsDirty = false
            shared.writeIsScheduled = false
            return (states, removed, index)
        }
        guard !states.isEmpty || !removed.isEmpty || index != nil else { return }
        let encoder = Self.encoder
        var failed = Set<UUID>()
        try? FileManager.default.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)
        for (id, state) in states {
            do {
                try encoder.encode(state).write(to: stateURL(for: id), options: .atomic)
            } catch {
                failed.insert(id)
                Self.log.error("Couldn't write state \(id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        var removalsFailed = Set<UUID>()
        for id in removed {
            let url = stateURL(for: id)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do { try FileManager.default.removeItem(at: url) } catch { removalsFailed.insert(id) }
        }
        var indexFailed = false
        if let index {
            if failed.isEmpty {
                do {
                    let file = IndexFile(documents: Dictionary(uniqueKeysWithValues: index.map { ($0.key.uuidString, $0.value) }))
                    try encoder.encode(file).write(to: indexURL, options: .atomic)
                } catch {
                    indexFailed = true
                    Self.log.error("Couldn't write index.json: \(error.localizedDescription, privacy: .public)")
                }
            } else {
                indexFailed = true
            }
        }
        guard !failed.isEmpty || !removalsFailed.isEmpty || indexFailed else { return }
        shared.withLock { shared in
            // Anything changed or removed again meanwhile is already pending.
            for id in failed where shared.states[id] != nil && !shared.removed.contains(id) {
                shared.dirty.insert(id)
            }
            shared.removed.formUnion(removalsFailed.filter { shared.index?[$0] == nil })
            if indexFailed { shared.indexIsDirty = true }
        }
        scheduleWrite(after: retryDelay)
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// One spelling per file, so a path from a bookmark and a path from an
    /// open panel compare equal. Inside the sandbox `resolvingSymlinksInPath`
    /// leaves `/tmp` unresolved while bookmarks resolve to `/private/tmp`
    /// (seen on macOS 26), so the canonical path is preferred.
    static func path(of url: URL) -> String {
        if let canonical = (try? url.resourceValues(forKeys: [.canonicalPathKey]))?.canonicalPath {
            return canonical
        }
        return url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

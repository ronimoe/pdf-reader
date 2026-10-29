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
/// private queue. `flush()` writes everything now; call it when a document
/// closes and when the app quits. The root directory is injected, so tests
/// never touch the app's container.
public final class DocumentStateStore: Sendable {
    public let directory: URL
    private let bookmarks: any FileBookmarking
    private let debounce: Duration
    private let queue = DispatchQueue(label: "io.github.ronimoe.Lectern.DocumentStateStore")
    private let shared = Mutex(Shared())
    private static let log = Logger(subsystem: "io.github.ronimoe.Lectern", category: "DocumentStateStore")

    private struct Shared: Sendable {
        var index: [UUID: IndexEntry]?
        var states: [UUID: DocumentState] = [:]
        var dirty: Set<UUID> = []
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

    public init(directory: URL, bookmarks: any FileBookmarking = SecurityScopedBookmarks(), debounce: Duration = .seconds(1)) {
        self.directory = directory
        self.bookmarks = bookmarks
        self.debounce = debounce
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

    // MARK: Opening

    /// The identity of the file at `url` with contents `data`.
    public func identity(for url: URL, data: Data, pageCount: Int) -> DocumentIdentity {
        DocumentIdentity(
            bookmark: bookmarks.bookmarkData(for: url),
            fileIdentifiers: DocumentIdentity.fileIdentifiers(ofPDF: data),
            pageCount: pageCount,
            fileSize: data.count,
            lastKnownPath: Self.path(of: url),
            fingerprint: DocumentIdentity.fingerprint(of: data),
            fileNumber: DocumentIdentity.fileNumber(of: url)
        )
    }

    /// Finds the stored state for the file that is opening, or starts a new
    /// record (A2). The record's identity is refreshed, including a new
    /// bookmark, so a stale one is replaced.
    @discardableResult
    public func open(url: URL, data: Data, pageCount: Int, now: Date = Date()) -> StoredDocument {
        let identity = identity(for: url, data: data, pageCount: pageCount)
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
        return StoredDocument(id: id, state: stored, match: match)
    }

    // MARK: Reading and changing

    public func state(for id: UUID) -> DocumentState? {
        loadedState(for: id)
    }

    /// Changes a document's state. The write happens after the debounce.
    public func update(_ id: UUID, _ change: (inout DocumentState) -> Void) {
        guard var state = loadedState(for: id) else { return }
        change(&state)
        save(state, for: id)
    }

    /// Writes every pending change now, on the caller's thread's behalf.
    public func flush() {
        queue.sync { writePending() }
    }

    // MARK: Internals

    private func save(_ state: DocumentState, for id: UUID) {
        _ = loadedIndex()
        let shouldSchedule = shared.withLock { shared -> Bool in
            let previous = shared.states[id]
            guard previous != state else { return false }
            shared.states[id] = state
            shared.dirty.insert(id)
            let entry = IndexEntry(identity: state.identity, lastOpened: state.lastOpened)
            if shared.index?[id] != entry {
                shared.index?[id] = entry
                shared.indexIsDirty = true
            }
            guard !shared.writeIsScheduled else { return false }
            shared.writeIsScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        let components = debounce.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.writePending()
        }
    }

    private func loadedIndex() -> [UUID: IndexEntry] {
        if let index = shared.withLock({ $0.index }) { return index }
        var loaded: [UUID: IndexEntry] = [:]
        if let data = try? Data(contentsOf: indexURL) {
            do {
                let file = try Self.decoder.decode(IndexFile.self, from: data)
                for (key, entry) in file.documents {
                    if let id = UUID(uuidString: key) { loaded[id] = entry }
                }
            } catch {
                Self.log.error("index.json is unreadable and will be rebuilt: \(error.localizedDescription, privacy: .public)")
            }
        }
        return shared.withLock { shared in
            if let index = shared.index { return index }
            shared.index = loaded
            return loaded
        }
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

    /// Runs on `queue` only, so writes never interleave.
    private func writePending() {
        let (states, index) = shared.withLock { shared -> ([UUID: DocumentState], [UUID: IndexEntry]?) in
            let states = shared.dirty.reduce(into: [UUID: DocumentState]()) { result, id in result[id] = shared.states[id] }
            shared.dirty.removeAll()
            let index = shared.indexIsDirty ? shared.index : nil
            shared.indexIsDirty = false
            shared.writeIsScheduled = false
            return (states, index)
        }
        guard !states.isEmpty || index != nil else { return }
        let encoder = Self.encoder
        do {
            try FileManager.default.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)
            for (id, state) in states {
                try encoder.encode(state).write(to: stateURL(for: id), options: .atomic)
            }
            if let index {
                let file = IndexFile(documents: Dictionary(uniqueKeysWithValues: index.map { ($0.key.uuidString, $0.value) }))
                try encoder.encode(file).write(to: indexURL, options: .atomic)
            }
        } catch {
            Self.log.error("Couldn't write document state: \(error.localizedDescription, privacy: .public)")
        }
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

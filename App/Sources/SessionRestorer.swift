import AppKit
import ReaderCore

/// The windows and tabs open when Lectern last quit (B3, spec §5.4). Each pane's place, the split
/// and the sidebar aren't here: they are the per-document state (A2), which reopening a document
/// restores anyway.
struct SessionState: Codable, Equatable {
    struct Tab: Codable, Equatable {
        /// Security-scoped bookmark data for the file.
        var bookmark: Data?
        var path: String
        var distractionFree: Bool
    }

    struct Window: Codable, Equatable {
        /// `NSStringFromRect` of the window frame.
        var frame: String
        var tabs: [Tab]
        var selectedTab: Int
    }

    /// Front to back.
    var windows: [Window]

    static let empty = SessionState(windows: [])
}

/// Saves and restores the session with Lectern's own state rather than AppKit's window
/// restoration (architecture §6, amended in M5): the policy needs "Always" to work even when macOS
/// closes windows on quit, missing files must be skipped silently, and every step can be tested
/// in-process. AppKit's restoration is turned off on every Lectern window so the two never both
/// reopen a document.
final class SessionRestorer {
    let fileURL: URL
    var policy: () -> SessionRestorePolicy
    var systemKeepsWindows: () -> Bool
    /// Opens a file as a document without showing it. Errors are skipped silently.
    var openDocument: (URL) async throws -> NSDocument = { url in
        try await NSDocumentController.shared.openDocument(withContentsOf: url, display: false).0
    }
    /// Called on each restored window before it is ordered in (it must not order the window in
    /// itself); tests make it invisible.
    var prepareWindow: (NSWindow) -> Void = { _ in }
    /// Makes the front window key once everything is in place. Only that window, so only that
    /// tab asks for a password at launch (B6); the others ask when they become key.
    var makeKey: (NSWindow) -> Void = { $0.makeKeyAndOrderFront(nil) }
    /// The reader windows whose session is saved.
    var currentControllers: () -> [ReaderWindowController] = {
        NSDocumentController.shared.documents.compactMap { ($0 as? ReaderDocument)?.readerWindowController }
    }
    /// A restored frame smaller than this (or empty, from a damaged file) is ignored.
    static let minimumFrameSize = NSSize(width: 320, height: 240)
    /// Set while quitting: documents closing during the quit don't shrink the saved session.
    private(set) var isTerminating = false
    private var accessedURLs: [URL] = []

    init(
        fileURL: URL,
        policy: @escaping () -> SessionRestorePolicy,
        systemKeepsWindows: @escaping () -> Bool = { SessionRestorer.systemKeepsWindows() }
    ) {
        self.fileURL = fileURL
        self.policy = policy
        self.systemKeepsWindows = systemKeepsWindows
    }

    /// macOS's System Settings ▸ Desktop & Dock ▸ "Close windows when quitting an application" is
    /// off. (`NSQuitAlwaysKeepsWindows` lives in the global domain; unset means close.)
    static func systemKeepsWindows() -> Bool {
        UserDefaults.standard.bool(forKey: "NSQuitAlwaysKeepsWindows")
    }

    /// `-ApplePersistenceIgnoreState YES` on the command line (a test launch, such as
    /// scripts/release/verify-dmg's): last session is neither restored nor overwritten.
    var ignoresPersistentState: () -> Bool = { SessionRestorer.launchIgnoresPersistentState() }

    static let ignoreStateArgument = "ApplePersistenceIgnoreState"

    /// Only the launch arguments count: someone who set `ApplePersistenceIgnoreState` globally
    /// (`defaults write -g …`) keeps session restore and scheduled update checks.
    static func launchIgnoresPersistentState() -> Bool {
        argumentFlag(ignoreStateArgument, in: UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain))
    }

    /// A Boolean from the argument domain (`-Key YES`).
    static func argumentFlag(_ key: String, in arguments: [String: Any]) -> Bool {
        switch arguments[key] {
        case let value as Bool: value
        case let value as NSNumber: value.boolValue
        case let value as String: ["yes", "true", "1"].contains(value.lowercased())
        default: false
        }
    }

    var shouldRestore: Bool {
        !ignoresPersistentState() && policy().shouldRestore(systemKeepsWindows: systemKeepsWindows())
    }

    // MARK: Saving

    /// The reader windows now, grouped into windows of tabs, front to back.
    static func capture(_ controllers: [ReaderWindowController], orderedWindows: [NSWindow] = NSApp.orderedWindows) -> SessionState {
        var groups: [[ReaderWindowController]] = []
        var seen = Set<ObjectIdentifier>()
        let byWindow = Dictionary(controllers.compactMap { c in c.window.map { (ObjectIdentifier($0), c) } }, uniquingKeysWith: { a, _ in a })
        for controller in controllers {
            guard let window = controller.window, !seen.contains(ObjectIdentifier(window)) else { continue }
            let tabWindows = window.tabGroup?.windows ?? [window]
            let group = tabWindows.compactMap { byWindow[ObjectIdentifier($0)] }
            group.forEach { if let w = $0.window { seen.insert(ObjectIdentifier(w)) } }
            if !group.isEmpty { groups.append(group) }
        }
        func zIndex(_ group: [ReaderWindowController]) -> Int {
            group.compactMap { $0.window.flatMap { orderedWindows.firstIndex(of: $0) } }.min() ?? Int.max
        }
        groups.sort { zIndex($0) < zIndex($1) }
        let windows: [SessionState.Window] = groups.compactMap { group in
            let tabs = group.compactMap { controller -> SessionState.Tab? in
                guard let url = (controller.document as? NSDocument)?.fileURL else { return nil }
                return SessionState.Tab(
                    bookmark: try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil),
                    path: url.path,
                    distractionFree: controller.isDistractionFree
                )
            }
            guard !tabs.isEmpty, let first = group.first?.window else { return nil }
            let selected = first.tabGroup?.selectedWindow.flatMap { selected in group.firstIndex { $0.window === selected } } ?? 0
            let frameWindow = first.tabGroup?.selectedWindow ?? first
            return SessionState.Window(frame: NSStringFromRect(frameWindow.frame), tabs: tabs, selectedTab: selected)
        }
        return SessionState(windows: windows)
    }

    /// Writes the session, but only while it could be restored: with "Never", or "As set in
    /// System Settings" while macOS closes windows on quit, the file is deleted instead, so no
    /// list of open files is kept that nothing will read.
    func save(_ state: SessionState) {
        guard !ignoresPersistentState() else { return }
        if !policy().shouldRestore(systemKeepsWindows: systemKeepsWindows()) || state.windows.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    func saveCurrentSession() {
        save(Self.capture(currentControllers()))
    }

    /// While running: kept up to date as documents open and close, so a crash still restores.
    func documentsDidChange() {
        guard !isTerminating else { return }
        saveCurrentSession()
    }

    /// At quit, before any window closes.
    func applicationWillQuit() {
        saveCurrentSession()
        isTerminating = true
    }

    /// The user cancelled the quit (in the unsaved-changes review): keep saving as before.
    func quitWasCancelled() {
        isTerminating = false
    }

    func load() -> SessionState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(SessionState.self, from: data)
    }

    // MARK: Restoring

    /// Reopens last session's windows and tabs if the policy says so. Files that are gone or
    /// can't be opened are skipped without a word (no error storm). Returns the documents
    /// reopened.
    @discardableResult
    func restore() async -> [NSDocument] {
        guard shouldRestore, let state = load() else { return [] }
        var reopened: [NSDocument] = []
        var seenFiles = Set<String>()
        var frontWindow: NSWindow?
        // Back to front, so the frontmost window ends up in front.
        for saved in state.windows.reversed() {
            var controllers: [(ReaderWindowController, SessionState.Tab)] = []
            var savedIndices: [Int] = []
            for (index, tab) in saved.tabs.enumerated() {
                guard let resolved = resolve(tab) else { continue }
                // The same file listed twice comes back once.
                let key = resolved.url.standardizedFileURL.resolvingSymlinksInPath().path
                guard seenFiles.insert(key).inserted else {
                    release(resolved)
                    continue
                }
                guard let document = try? await openDocument(resolved.url) else {
                    release(resolved)
                    continue
                }
                if document.windowControllers.isEmpty { document.makeWindowControllers() }
                // Already open (by Finder at launch, say), or not a reader document: leave it.
                guard let controller = (document as? ReaderDocument)?.readerWindowController,
                      controller.window?.isVisible != true
                else {
                    release(resolved)
                    continue
                }
                keep(resolved)
                // A password is asked for only when this tab's window becomes key, not on show.
                controller.defersPasswordCheckUntilKey = true
                reopened.append(document)
                controllers.append((controller, tab))
                savedIndices.append(index)
            }
            guard let (first, _) = controllers.first, let firstWindow = first.window else { continue }
            let frame = Self.usableFrame(saved.frame)
            for (controller, _) in controllers {
                guard let window = controller.window else { continue }
                prepareWindow(window)
                if let frame { window.setFrame(frame, display: false) }
            }
            // A new window, not a tab of whatever is in front: tabbing is off while it orders in.
            // Ordered in without becoming key; only the front window becomes key, at the end.
            let mode = firstWindow.tabbingMode
            firstWindow.tabbingMode = .disallowed
            firstWindow.orderFront(nil)
            firstWindow.tabbingMode = mode
            var previous = firstWindow
            for (controller, _) in controllers.dropFirst() {
                guard let window = controller.window else { continue }
                previous.addTabbedWindow(window, ordered: .above)
                previous = window
            }
            // Distraction-free tabs first, then the selection, then the frame.
            for (controller, tab) in controllers where tab.distractionFree {
                controller.setDistractionFree(true)
            }
            // The saved selection, or the tab before it if that file is gone.
            let selectedPosition = savedIndices.lastIndex { $0 <= saved.selectedTab } ?? 0
            let selected = controllers[selectedPosition].0
            if let window = selected.window {
                window.tabGroup?.selectedWindow = window
                // A tab group takes one frame; make sure it's the saved one.
                if let frame { window.setFrame(frame, display: true) }
                frontWindow = window
            }
        }
        if let frontWindow { makeKey(frontWindow) }
        return reopened
    }

    /// The saved frame, unless it is damaged, empty or too small to use.
    static func usableFrame(_ string: String) -> NSRect? {
        let frame = NSRectFromString(string)
        guard frame.width.isFinite, frame.height.isFinite, frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width >= minimumFrameSize.width, frame.height >= minimumFrameSize.height
        else { return nil }
        return frame
    }

    struct ResolvedTab {
        let url: URL
        /// Security-scoped access was started for it and must be stopped unless it's kept.
        let isScoped: Bool
    }

    /// The file a saved tab points at, through its bookmark (which follows moves), or its path.
    /// Nil when it's gone. Access to a bookmarked file starts before it is looked at: inside the
    /// sandbox, a file outside the container can't even be seen without it.
    func resolve(_ tab: SessionState.Tab) -> ResolvedTab? {
        if let bookmark = tab.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) {
                let scoped = url.startAccessingSecurityScopedResource()
                if FileManager.default.fileExists(atPath: url.path) { return ResolvedTab(url: url, isScoped: scoped) }
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
        }
        let url = URL(fileURLWithPath: tab.path)
        return FileManager.default.fileExists(atPath: url.path) ? ResolvedTab(url: url, isScoped: false) : nil
    }

    /// Held while the app runs: the document reads now and may save later.
    private func keep(_ resolved: ResolvedTab) {
        if resolved.isScoped { accessedURLs.append(resolved.url) }
    }

    /// A skipped tab gives its access back.
    private func release(_ resolved: ResolvedTab) {
        if resolved.isScoped { resolved.url.stopAccessingSecurityScopedResource() }
        releasedCount += 1
    }

    /// For tests: how many resolved tabs were skipped and gave their access back.
    private(set) var releasedCount = 0
    var heldURLs: [URL] { accessedURLs }
}

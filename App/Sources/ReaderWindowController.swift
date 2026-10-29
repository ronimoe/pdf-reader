import AppKit
import PDFKit
import Persistence
import ReaderCore
import ReaderKit
import ReaderUI

/// One reader window (or tab) for one document. Owns the document's view
/// settings, the pane and its history, the sidebar, search, the toolbar, the
/// reading commands, the unlock flow (B6), and the document's stored state
/// (A2).
final class ReaderWindowController: NSWindowController {
    /// The one pane until the split view lands in M3.
    let pane = ReaderPane(id: .primary)
    var pdfView: ReaderPDFView { pane.view }
    /// The layout, zoom, rotation and sidebar of this document (B1, B9),
    /// stored per document.
    private(set) var settings = ViewSettings() {
        didSet {
            if settings != oldValue { updateStoredState { $0.viewSettings = self.settings } }
        }
    }
    /// The password sheet's model while it is showing.
    private(set) var passwordPrompt: PasswordPromptModel?
    /// The Go to Page sheet's model while it is showing.
    private(set) var goToPagePrompt: GoToPageModel?

    let splitViewController = NSSplitViewController()
    let outlineSection = OutlineSectionViewController()
    let thumbnailsSection = ThumbnailsSectionViewController()
    let searchSection = SearchResultsSectionViewController()
    private(set) lazy var sidebar = SidebarViewController(
        sections: [thumbnailsSection, outlineSection, searchSection],
        visible: settings.sidebar.section
    )
    private(set) var sidebarItem: NSSplitViewItem!
    let notice = NoticeView()

    // Search (B8)
    private(set) var search: DocumentSearch?
    private(set) var searchOptions = SearchOptions()
    private(set) var currentResultIndex: Int?
    private(set) var searchField: NSSearchField?
    private var searchItem: NSSearchToolbarItem?
    /// The section to go back to when a search ends.
    private var sectionBeforeSearch: SidebarSection?

    // Background work on the document's bytes (architecture §4.6)
    private(set) var renderer: PageRenderer?
    private var textInventory: TextInventory?
    private(set) var pagesWithoutText: [Int]?

    // Stored state (A2)
    private let stateStore: DocumentStateStore?
    private(set) var storedDocumentID: UUID?
    private var anchorSave: DispatchWorkItem?
    private var collapseObservation: NSKeyValueObservation?
    /// Set while the sidebar opens or closes for a reason other than the
    /// user's choice (a search showing its results), so it isn't remembered.
    private var isMovingSidebarForSearch = false

    private weak var readerDocument: ReaderDocument?
    private let passwordStore: any DocumentPasswordStore
    private let presenter: any ReaderPresenting
    private var didCheckPasswords = false

    init(
        document: ReaderDocument,
        passwordStore: any DocumentPasswordStore = KeychainPasswordStore(),
        presenter: any ReaderPresenting = SheetPresenter(),
        stateStore: DocumentStateStore? = AppEnvironment.stateStore
    ) {
        readerDocument = document
        self.passwordStore = passwordStore
        self.presenter = presenter
        self.stateStore = stateStore
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 1000),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "ReaderWindow"
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.titleVisibility = .visible
        window.toolbarStyle = .unifiedCompact
        window.setFrameAutosaveName("ReaderWindow")
        super.init(window: window)

        buildContent(in: window)
        window.toolbar = makeToolbar()
        pdfView.onUserZoom = { [weak self] scale in self?.settings.zoom = .scale(scale) }
        pdfView.onCopyBlocked = { [weak self] in self?.explainBlocked(.copy) }
        pdfView.onOpenFiles = { urls in ReaderDocumentController.openDocuments(at: urls) }
        pdfView.contextMenuItems = {
            ReaderCommands.zoomItems() + [.separator()] + ReaderCommands.readingOptionItems()
        }
        pane.onHistoryChange = { [weak self] history in
            guard let self else { return }
            updateStoredState { $0.history[self.pane.id] = history }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(pageDidChange(_:)), name: .PDFViewPageChanged, object: pdfView)
        pdfView.onVisibleAreaChange = { [weak self] in self?.saveAnchorSoon() }
        window.delegate = self
        showContentIfReadable()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Sidebar and reading area side by side, in a split view whose sidebar
    /// collapses (spec §4.1).
    private func buildContent(in window: NSWindow) {
        let reading = NSViewController()
        let container = NSView()
        container.addSubview(pdfView)
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        notice.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(notice)
        NSLayoutConstraint.activate([
            pdfView.topAnchor.constraint(equalTo: container.topAnchor),
            pdfView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            pdfView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            notice.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 12),
            notice.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            notice.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -40),
        ])
        reading.view = container

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.canCollapse = true
        sidebarItem.minimumThickness = 170
        sidebarItem.maximumThickness = 420
        sidebarItem.isCollapsed = true
        self.sidebarItem = sidebarItem
        splitViewController.splitViewItems = [sidebarItem, NSSplitViewItem(viewController: reading)]
        splitViewController.view.frame = NSRect(origin: .zero, size: window.contentRect(forFrameRect: window.frame).size)
        window.contentViewController = splitViewController
        window.setContentSize(splitViewController.view.frame.size)

        sidebar.setHidden(true, for: .search)
        sidebar.onSectionChange = { [weak self] section in self?.settings.sidebar.section = section }
        outlineSection.onJump = { [weak self] outline in self?.jump(to: outline) }
        thumbnailsSection.onJump = { [weak self] index in self?.pane.jump(toPageAt: index) }
        searchSection.onShowResult = { [weak self] index in self?.showResult(at: index) }
        collapseObservation = sidebarItem.observe(\.isCollapsed, options: [.new]) { [weak self] item, _ in
            let collapsed = item.isCollapsed
            MainActor.assumeIsolated { self?.sidebarCollapsedDidChange(collapsed) }
        }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        checkPasswordsIfNeeded()
    }

    // Restored windows can come back without showWindow; checking when the
    // window first becomes key covers them.
    func windowDidBecomeKey(_ notification: Notification) {
        checkPasswordsIfNeeded()
    }

    /// True once the pages are on screen (the document is unlocked).
    var isShowingContent: Bool { pdfView.document != nil }

    private func showContentIfReadable() {
        guard !isShowingContent, let readerDocument, !readerDocument.isPasswordLocked,
              let pdf = readerDocument.pdfDocument
        else { return }
        let stored = openStoredState(for: readerDocument, pdf: pdf)
        readerDocument.applyViewRotation(settings.rotation)
        pdfView.document = pdf
        pdfView.apply(settings, hints: readerDocument.layoutHints)
        configureSidebar(for: readerDocument, pdf: pdf)
        if let anchor = stored?.anchor {
            // Restore once the view has its real size; the anchor then holds
            // through any later resize until the user scrolls.
            splitViewController.view.layoutSubtreeIfNeeded()
            pdfView.restore(anchor)
        }
        window?.makeFirstResponder(pdfView)
    }

    // MARK: Stored state (A2)

    /// Loads what was remembered about this file: the view settings, the
    /// sidebar, the pane's history and the reading position. Documents
    /// without a file (tests) have nothing stored.
    private func openStoredState(for document: ReaderDocument, pdf: PDFDocument) -> DocumentState? {
        guard let stateStore, let url = document.fileURL else { return nil }
        let stored = stateStore.open(url: url, data: document.originalData, pageCount: pdf.pageCount)
        storedDocumentID = stored.id
        var restored = stored.state.viewSettings
        if stored.match == .new, pdf.outlineRoot.map({ $0.numberOfChildren > 0 }) == true {
            // A document with a table of contents opens the sidebar on it.
            restored.sidebar.section = .outline
        }
        settings = restored
        pane.setHistory(stored.state.history[pane.id] ?? HistoryStack())
        return stored.state
    }

    private func updateStoredState(_ change: (inout DocumentState) -> Void) {
        guard let stateStore, let storedDocumentID else { return }
        stateStore.update(storedDocumentID, change)
    }

    /// Scrolling never makes a history entry, but the reading position is
    /// remembered a moment after it settles.
    private func saveAnchorSoon() {
        guard storedDocumentID != nil else { return }
        anchorSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveAnchor() }
        }
        anchorSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func saveAnchor() {
        anchorSave?.cancel()
        anchorSave = nil
        guard isShowingContent, let anchor = pdfView.currentAnchor else { return }
        updateStoredState { $0.anchor = anchor }
    }

    /// Saves the reading position and writes everything out now: the window
    /// is closing or the app is quitting.
    func saveStateNow() {
        saveAnchor()
        stateStore?.flush()
    }

    func windowWillClose(_ notification: Notification) {
        saveStateNow()
        search?.cancel()
    }

    // MARK: Sidebar (spec §4.1)

    private func configureSidebar(for document: ReaderDocument, pdf: PDFDocument) {
        renderer = PageRenderer(data: document.originalData, password: document.sessionPassword)
        textInventory = TextInventory(data: document.originalData, password: document.sessionPassword)
        pagesWithoutText = nil
        outlineSection.setDocument(pdf)
        thumbnailsSection.configure(document: pdf, renderer: renderer, numbering: document.pageNumbering, rotation: settings.rotation)
        sidebar.show(settings.sidebar.section)
        sidebarItem.isCollapsed = !settings.sidebar.isVisible
        if let page = pdfView.currentPage { thumbnailsSection.setCurrentPage(pdf.index(for: page)) }
    }

    var isSidebarVisible: Bool { !sidebarItem.isCollapsed }

    @objc func toggleReaderSidebar(_ sender: Any?) {
        setSidebarVisible(!isSidebarVisible)
    }

    func setSidebarVisible(_ visible: Bool) {
        sidebarItem.isCollapsed = !visible
        settings.sidebar.isVisible = visible
    }

    @objc func showThumbnails(_ sender: Any?) { showSidebarSection(.thumbnails) }
    @objc func showTableOfContents(_ sender: Any?) { showSidebarSection(.outline) }

    func showSidebarSection(_ section: SidebarSection) {
        sidebar.show(section)
        if section != .search { settings.sidebar.section = section }
        setSidebarVisible(true)
    }

    private func sidebarCollapsedDidChange(_ collapsed: Bool) {
        // Dragging the divider closed counts as hiding it.
        if !isMovingSidebarForSearch, settings.sidebar.isVisible == collapsed, isShowingContent {
            settings.sidebar.isVisible = !collapsed
        }
    }

    @objc private func pageDidChange(_ notification: Notification) {
        guard let document = pdfView.document, let page = pdfView.currentPage else { return }
        thumbnailsSection.setCurrentPage(document.index(for: page))
    }

    private func jump(to outline: PDFOutline) {
        let destination = outline.destination ?? (outline.action as? PDFActionGoTo)?.destination
        guard let destination else { return }
        pane.jump(to: destination)
    }

    // MARK: Go to page

    @objc func showGoToPage(_ sender: Any?) {
        guard let window, let readerDocument, isShowingContent, goToPagePrompt == nil else { return }
        let current = pdfView.currentPage.flatMap { pdfView.document?.index(for: $0) } ?? 0
        let model = GoToPageModel(numbering: readerDocument.pageNumbering, currentPageIndex: current)
        model.onGo = { [weak self] index in
            self?.dismissGoToPage()
            self?.pane.jump(toPageAt: index)
        }
        model.onCancel = { [weak self] in self?.dismissGoToPage() }
        goToPagePrompt = model
        presenter.showGoToPage(model, on: window)
    }

    private func dismissGoToPage() {
        goToPagePrompt = nil
        if let window { presenter.dismissGoToPage(on: window) }
    }

    // MARK: History (B2)

    @objc func navigateBack(_ sender: Any?) { pane.goBack() }
    @objc func navigateForward(_ sender: Any?) { pane.goForward() }

    // MARK: Search (B8)

    /// ⌘F: puts the cursor in the search field.
    @objc func focusSearchField(_ sender: Any?) {
        guard isShowingContent, let window else { return }
        if window.toolbar?.isVisible == false { window.toolbar?.isVisible = true }
        if let searchItem {
            searchItem.beginSearchInteraction()
        } else if let searchField {
            window.makeFirstResponder(searchField)
        }
    }

    @objc func searchFieldChanged(_ sender: NSSearchField) {
        let query = sender.stringValue
        guard !query.isEmpty else {
            endSearch()
            return
        }
        // Return in the field steps through the results of the same query.
        if query == search?.query, let event = NSApp.currentEvent, event.type == .keyDown,
           event.keyCode == 36 || event.keyCode == 76 {
            showNextResult(sender)
            return
        }
        startSearch(query)
    }

    /// Searches for `query`. The first search of a session remembers where
    /// reading was; refining the query keeps the same session.
    func startSearch(_ query: String) {
        guard let document = pdfView.document, !query.isEmpty else { return }
        if search == nil {
            pane.beginSearchSession()
            let search = DocumentSearch(document: document)
            search.onChange = { [weak self] in self?.searchDidChange() }
            self.search = search
            sectionBeforeSearch = sidebar.visibleSection
            searchSection.setSearch(search, numbering: readerDocument?.pageNumbering ?? PageNumbering(pageCount: document.pageCount))
        }
        if searchField?.stringValue != query { searchField?.stringValue = query }
        currentResultIndex = nil
        search?.pagesWithoutText = pagesWithoutText?.count
        search?.start(query, options: searchOptions)
        sidebar.setHidden(false, for: .search)
        sidebar.show(.search)
        setSidebarCollapsedForSearch(false)
        loadTextInventoryIfNeeded()
    }

    /// Escape or an empty field: the session ends, highlights go, and the
    /// sidebar returns to the section it showed before.
    func endSearch() {
        guard let search else { return }
        search.cancel()
        self.search = nil
        currentResultIndex = nil
        pane.endSearchSession()
        pdfView.highlightedSelections = nil
        pdfView.clearSelection()
        searchSection.setSearch(nil, numbering: PageNumbering(pageCount: 0))
        if searchField?.stringValue.isEmpty == false { searchField?.stringValue = "" }
        sidebar.setHidden(true, for: .search)
        sidebar.show(sectionBeforeSearch ?? settings.sidebar.section)
        setSidebarCollapsedForSearch(!settings.sidebar.isVisible)
        sectionBeforeSearch = nil
    }

    private func setSidebarCollapsedForSearch(_ collapsed: Bool) {
        isMovingSidebarForSearch = true
        sidebarItem.isCollapsed = collapsed
        isMovingSidebarForSearch = false
    }

    var isSearching: Bool { search != nil }

    override func cancelOperation(_ sender: Any?) {
        if isSearching { endSearch() }
    }

    private func searchDidChange() {
        searchSection.reload()
        guard let search else { return }
        let shown = search.results.prefix(SearchResultsSectionViewController.rowLimit)
        pdfView.highlightedSelections = shown.isEmpty ? nil : shown.map(\.selection)
    }

    @objc func showNextResult(_ sender: Any?) { stepResult(by: 1) }
    @objc func showPreviousResult(_ sender: Any?) { stepResult(by: -1) }

    private func stepResult(by step: Int) {
        guard let count = search?.results.count, count > 0 else { return }
        let next: Int
        if let currentResultIndex {
            next = (currentResultIndex + step + count) % count
        } else {
            next = step > 0 ? 0 : count - 1
        }
        showResult(at: next)
    }

    func showResult(at index: Int) {
        guard let results = search?.results, results.indices.contains(index) else { return }
        currentResultIndex = index
        pane.show(results[index].selection)
        searchSection.selectResult(index)
    }

    @objc func toggleMatchCase(_ sender: Any?) {
        searchOptions.matchCase.toggle()
        rerunSearch()
    }

    @objc func toggleWholeWord(_ sender: Any?) {
        searchOptions.wholeWord.toggle()
        rerunSearch()
    }

    private func rerunSearch() {
        guard let query = search?.query, !query.isEmpty else { return }
        startSearch(query)
    }

    private func loadTextInventoryIfNeeded() {
        guard pagesWithoutText == nil, let textInventory else { return }
        Task { [weak self] in
            let missing = await textInventory.pagesWithoutText()
            guard let self else { return }
            pagesWithoutText = missing
            search?.pagesWithoutText = missing.count
        }
    }

    /// Waits for the text inventory, for tests.
    func waitForTextInventory() async {
        guard let textInventory else { return }
        let missing = await textInventory.pagesWithoutText()
        pagesWithoutText = missing
        search?.pagesWithoutText = missing.count
    }

    // MARK: Changes on disk (B7)

    /// The document reloaded silently: keep the reader's place, the history
    /// (clamped to the new page count) and any search, then say so briefly.
    func documentDidReload() {
        guard let readerDocument else { return }
        let anchor = pdfView.currentAnchor
        let query = search?.query
        if isSearching {
            search?.cancel()
            search = nil
            pdfView.highlightedSelections = nil
        }
        guard let pdf = readerDocument.pdfDocument, !readerDocument.isPasswordLocked else {
            // The new file needs a password the old one didn't.
            pdfView.document = nil
            didCheckPasswords = false
            checkPasswordsIfNeeded()
            return
        }
        pane.setHistory(pane.history.clamped(toPageCount: pdf.pageCount))
        readerDocument.applyViewRotation(settings.rotation)
        pdfView.document = pdf
        pdfView.apply(settings, hints: readerDocument.layoutHints)
        if let anchor { pdfView.restore(anchor.clamped(toPageCount: pdf.pageCount)) }
        configureSidebar(for: readerDocument, pdf: pdf)
        refreshStoredIdentity()
        if let query, !query.isEmpty {
            // Same session: no new history entry.
            let search = DocumentSearch(document: pdf)
            search.onChange = { [weak self] in self?.searchDidChange() }
            self.search = search
            searchSection.setSearch(search, numbering: readerDocument.pageNumbering)
            search.start(query, options: searchOptions)
            loadTextInventoryIfNeeded()
        }
        notice.show("Reloaded")
        saveAnchor()
    }

    /// Followed through file coordination: the window title updates itself,
    /// and the stored identity learns the new place.
    func documentDidMove(to url: URL) {
        refreshStoredIdentity()
    }

    private func refreshStoredIdentity() {
        guard let stateStore, let storedDocumentID, let readerDocument, let url = readerDocument.fileURL,
              let pdf = readerDocument.pdfDocument
        else { return }
        let identity = stateStore.identity(for: url, data: readerDocument.originalData, pageCount: pdf.pageCount)
        stateStore.update(storedDocumentID) { $0.identity = identity }
    }

    func showFileRemovedNotice() {
        let name = readerDocument?.displayName ?? "This document"
        notice.show("“\(name)” was deleted or moved to the Trash. It stays open here until you close it.", duration: nil)
    }

    // MARK: Passwords (B6)

    /// Tries a password remembered in the Keychain, then asks for one if the
    /// document is still locked. A remembered owner password also lifts the
    /// restrictions of a document that opened without one.
    func checkPasswordsIfNeeded() {
        guard let readerDocument, !didCheckPasswords else { return }
        didCheckPasswords = true
        if readerDocument.isPasswordLocked || !readerDocument.hasOwnerAccess,
           let stored = try? passwordStore.password(for: readerDocument.documentKey) {
            if readerDocument.unlock(withPassword: stored) {
                showContentIfReadable()
            } else {
                // The key includes this file's encryption entries, so the
                // entry is this file's own and its password no longer works.
                try? passwordStore.removePassword(for: readerDocument.documentKey)
            }
        }
        if readerDocument.isPasswordLocked {
            promptForPassword(.open)
        }
    }

    func promptForPassword(_ purpose: PasswordPromptModel.Purpose) {
        guard let window, let readerDocument else { return }
        let model = PasswordPromptModel(documentName: readerDocument.displayName, purpose: purpose)
        model.onSubmit = { [weak self] password, remember in
            self?.submitPassword(password, remember: remember, purpose: purpose) ?? false
        }
        model.onCancel = { [weak self] in self?.cancelPasswordPrompt(purpose) }
        passwordPrompt = model
        presenter.showPasswordPrompt(model, on: window)
    }

    /// Returns false for a wrong password, leaving the prompt up. On an open
    /// document only the owner password counts (see `ReaderDocument.unlock`).
    func submitPassword(_ password: String, remember: Bool, purpose: PasswordPromptModel.Purpose) -> Bool {
        guard let readerDocument, readerDocument.unlock(withPassword: password) else { return false }
        if remember {
            // Failing to remember never blocks reading; the user is asked next time.
            try? passwordStore.setPassword(password, for: readerDocument.documentKey)
        }
        dismissPasswordPrompt()
        showContentIfReadable()
        return true
    }

    /// Cancelling the open prompt closes the document; cancelling the owner
    /// prompt only dismisses it.
    func cancelPasswordPrompt(_ purpose: PasswordPromptModel.Purpose) {
        dismissPasswordPrompt()
        if purpose == .open {
            readerDocument?.close()
        }
    }

    private func dismissPasswordPrompt() {
        passwordPrompt = nil
        if let window { presenter.dismissPasswordPrompt(on: window) }
    }

    /// Tells the user why an action did nothing, and offers the owner password.
    func explainBlocked(_ action: BlockedAction) {
        guard let window else { return }
        presenter.explain(action, on: window) { [weak self] in
            self?.promptForPassword(.removeRestrictions)
        }
    }

    // MARK: Reading commands

    @objc func increaseZoom(_ sender: Any?) {
        settings.zoomIn(from: pdfView.scaleFactor)
        pdfView.setZoomMode(settings.zoom)
    }

    @objc func decreaseZoom(_ sender: Any?) {
        settings.zoomOut(from: pdfView.scaleFactor)
        pdfView.setZoomMode(settings.zoom)
    }

    @objc func zoomToActualSize(_ sender: Any?) { setZoom(.actualSize) }
    @objc func zoomToFitPage(_ sender: Any?) { setZoom(.fitPage) }
    @objc func zoomToFitWidth(_ sender: Any?) { setZoom(.fitWidth) }

    @objc func showSinglePage(_ sender: Any?) { updateLayout { $0.pages = .single } }
    @objc func showTwoPages(_ sender: Any?) { updateLayout { $0.pages = .twoUp } }
    @objc func scrollContinuously(_ sender: Any?) { updateLayout { $0.scrolling = .continuous } }
    @objc func scrollPageByPage(_ sender: Any?) { updateLayout { $0.scrolling = .paged } }

    @objc func toggleCoverPage(_ sender: Any?) {
        let hints = layoutHints
        updateLayout { $0.toggleCoverPageAlone(hints: hints) }
    }

    @objc func toggleRightToLeft(_ sender: Any?) {
        let hints = layoutHints
        updateLayout { $0.toggleRightToLeft(hints: hints) }
    }

    @objc func rotateDocumentLeft(_ sender: Any?) { updateLayout { $0.rotateLeft() } }
    @objc func rotateDocumentRight(_ sender: Any?) { updateLayout { $0.rotateRight() } }

    private var layoutHints: DocumentLayoutHints { readerDocument?.layoutHints ?? .none }

    private func setZoom(_ mode: ZoomMode) {
        settings.zoom = mode
        pdfView.setZoomMode(mode)
    }

    /// Applies a layout or rotation change, keeping the reader's place (A3).
    private func updateLayout(_ change: (inout ViewSettings) -> Void) {
        let rotation = settings.rotation
        change(&settings)
        pdfView.preservingAnchor {
            if settings.rotation != rotation {
                readerDocument?.applyViewRotation(settings.rotation)
                pdfView.layoutDocumentView()
            }
            pdfView.apply(settings, hints: layoutHints)
        }
        if settings.rotation != rotation {
            thumbnailsSection.setRotation(settings.rotation)
        }
    }

    // MARK: Validation

    private func isEnabled(_ action: Selector?) -> Bool {
        guard isShowingContent else { return false }
        switch action {
        case #selector(increaseZoom(_:)): return pdfView.scaleFactor < ZoomMode.maximumScale * 0.99
        case #selector(decreaseZoom(_:)): return pdfView.scaleFactor > ZoomMode.minimumScale * 1.01
        // Cover page and direction only change a two-page layout.
        case #selector(toggleCoverPage(_:)), #selector(toggleRightToLeft(_:)): return settings.pages == .twoUp
        case #selector(navigateBack(_:)): return pane.canGoBack
        case #selector(navigateForward(_:)): return pane.canGoForward
        case #selector(showNextResult(_:)), #selector(showPreviousResult(_:)): return (search?.results.isEmpty == false)
        default: return true
        }
    }

    private func isChecked(_ action: Selector?) -> Bool {
        switch action {
        case #selector(zoomToActualSize(_:)): settings.zoom == .actualSize
        case #selector(zoomToFitPage(_:)): settings.zoom == .fitPage
        case #selector(zoomToFitWidth(_:)): settings.zoom == .fitWidth
        case #selector(showSinglePage(_:)): settings.pages == .single
        case #selector(showTwoPages(_:)): settings.pages == .twoUp
        case #selector(scrollContinuously(_:)): settings.scrolling == .continuous
        case #selector(scrollPageByPage(_:)): settings.scrolling == .paged
        case #selector(toggleCoverPage(_:)): settings.effectiveCoverPageAlone(hints: layoutHints)
        case #selector(toggleRightToLeft(_:)): settings.effectiveRightToLeft(hints: layoutHints)
        case #selector(toggleMatchCase(_:)): searchOptions.matchCase
        case #selector(toggleWholeWord(_:)): searchOptions.wholeWord
        case #selector(showThumbnails(_:)): isSidebarVisible && sidebar.visibleSection == .thumbnails
        case #selector(showTableOfContents(_:)): isSidebarVisible && sidebar.visibleSection == .outline
        default: false
        }
    }
}

extension ReaderWindowController: NSWindowDelegate {}

extension ReaderWindowController: NSMenuItemValidation, NSToolbarItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleReaderSidebar(_:)) {
            menuItem.title = isSidebarVisible ? "Hide Sidebar" : "Show Sidebar"
        }
        // The search options stay available before a search starts.
        if menuItem.action == #selector(toggleMatchCase(_:)) || menuItem.action == #selector(toggleWholeWord(_:)) {
            menuItem.state = isChecked(menuItem.action) ? .on : .off
            return true
        }
        menuItem.state = isChecked(menuItem.action) ? .on : .off
        return isEnabled(menuItem.action)
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        isEnabled(item.action)
    }
}

// MARK: Toolbar

extension NSToolbarItem.Identifier {
    static let sidebar = Self("sidebar")
    static let goBack = Self("goBack")
    static let goForward = Self("goForward")
    static let zoomOut = Self("zoomOut")
    static let zoomIn = Self("zoomIn")
    static let zoomMenu = Self("zoomMenu")
    static let readingOptions = Self("readingOptions")
    static let search = Self("search")
}

extension ReaderWindowController: NSToolbarDelegate {
    private func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "ReaderToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        return toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebar, .sidebarTrackingSeparator, .goBack, .goForward, .flexibleSpace, .zoomOut, .zoomIn, .zoomMenu, .readingOptions, .search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebar, .sidebarTrackingSeparator, .goBack, .goForward, .zoomOut, .zoomIn, .zoomMenu, .readingOptions, .search, .space, .flexibleSpace]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case .sidebar:
            button(identifier, "Sidebar", "sidebar.left", #selector(toggleReaderSidebar(_:)), tip: "Show or hide the sidebar (⌃⌘S)")
        case .goBack:
            button(identifier, "Back", "chevron.backward", #selector(navigateBack(_:)), tip: "Go back (⌘[)")
        case .goForward:
            button(identifier, "Forward", "chevron.forward", #selector(navigateForward(_:)), tip: "Go forward (⌘])")
        case .zoomOut:
            button(identifier, "Zoom Out", "minus.magnifyingglass", #selector(decreaseZoom(_:)), tip: "Zoom out (⌘−)")
        case .zoomIn:
            button(identifier, "Zoom In", "plus.magnifyingglass", #selector(increaseZoom(_:)), tip: "Zoom in (⌘+)")
        case .zoomMenu:
            menu(identifier, "Zoom", "arrow.up.left.and.arrow.down.right", ReaderCommands.zoomItems(), tip: "Actual size and fit options")
        case .readingOptions:
            menu(identifier, "Reading Options", "rectangle.split.2x1", ReaderCommands.readingOptionItems(), tip: "Pages, scrolling and rotation")
        case .search:
            searchToolbarItem(identifier)
        default:
            nil
        }
    }

    private func searchToolbarItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSSearchToolbarItem(itemIdentifier: identifier)
        item.label = "Search"
        item.paletteLabel = "Search"
        item.toolTip = "Search the document’s text (⌘F)"
        let field = item.searchField
        field.placeholderString = "Search"
        field.sendsSearchStringImmediately = false
        field.sendsWholeSearchString = false
        field.target = self
        field.action = #selector(searchFieldChanged(_:))
        field.setAccessibilityLabel("Search document")
        let options = NSMenu(title: "Search Options")
        for item in ReaderCommands.searchOptionItems() {
            item.target = self
            options.addItem(item)
        }
        field.searchMenuTemplate = options
        searchItem = item
        searchField = field
        return item
    }

    private func button(_ identifier: NSToolbarItem.Identifier, _ label: String, _ symbol: String, _ action: Selector, tip: String) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = tip
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.isBordered = true
        item.action = action
        return item
    }

    private func menu(_ identifier: NSToolbarItem.Identifier, _ label: String, _ symbol: String, _ items: [NSMenuItem], tip: String) -> NSToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = tip
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        let menu = NSMenu(title: label)
        items.forEach(menu.addItem)
        item.menu = menu
        item.showsIndicator = true
        return item
    }
}

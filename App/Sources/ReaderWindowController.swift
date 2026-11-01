import AppKit
import PDFKit
import Persistence
import ReaderCore
import ReaderKit
import ReaderUI

/// One reader window (or tab) for one document. Owns the document's view
/// settings, the panes and their histories (one, or two when split, B3), the
/// sidebar, search, the toolbar, the reading commands, link previews (A3),
/// the unlock flow (B6), and the document's stored state (A2).
final class ReaderWindowController: NSWindowController {
    /// The first pane, always present. When the split closes, whichever pane
    /// stays is this one.
    let primaryPane = ReaderPane(id: .primary)
    /// The second pane while the tab is split.
    var secondaryPane: ReaderPane?
    var focusedPaneID: PaneID = .primary
    /// The focused pane: the sidebar, search, Go to Page, zoom and Back and
    /// Forward act on it.
    var pane: ReaderPane { focusedPane }
    var focusedPane: ReaderPane { focusedPaneID == .secondary ? secondaryPane ?? primaryPane : primaryPane }
    var pdfView: ReaderPDFView { focusedPane.view }
    var panes: [ReaderPane] { [primaryPane] + (secondaryPane.map { [$0] } ?? []) }
    var isSplit: Bool { secondaryPane != nil }
    /// The panes side by side, inside the reading area.
    let readingSplit = NSSplitViewController()
    var paneContainers: [PaneID: PaneContainerView] = [:]
    private var firstResponderObservation: NSKeyValueObservation?

    // Links (A3, A4)
    let previewPresenter: any LinkPreviewPresenting
    let urlOpener: any URLOpening
    let preferences: ReaderPreferences
    /// The preview showing now, and the pane it previews from.
    var linkPreview: LinkPreviewController?
    weak var linkPreviewSource: ReaderPane?
    var hoverDismissTimer: Timer?
    private var preferencesObserver: (any NSObjectProtocol)?
    /// The layout, zoom, rotation and sidebar of this document (B1, B9),
    /// stored per document.
    var settings = ViewSettings() {
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
    let annotationsSection = AnnotationsSectionViewController()
    let bookmarksSection = BookmarksSectionViewController()
    private(set) lazy var sidebar = SidebarViewController(
        sections: [thumbnailsSection, outlineSection, bookmarksSection, annotationsSection, searchSection],
        visible: settings.sidebar.section
    )
    private(set) var sidebarItem: NSSplitViewItem!
    let notice = NoticeView()
    /// "This document has form fields…" (A5), along the bottom of the reading area.
    let formInfoLine = InfoLineView()

    // Annotations (M4)
    /// The crash journal (A1); nil for documents without stored state.
    let journal: AnnotationJournal?
    /// Opens a file as a document: B7's Save a Copy opens the copy. Tests record instead.
    var openCopy: (URL) -> Void = { url in ReaderDocumentController.openDocuments(at: [url]) }
    var isAskingAboutChangedFile = false
    var didCheckJournal = false
    var annotationListCache: [(item: AnnotationListItem, annotation: PDFAnnotation)]?

    // Search (B8)
    private(set) var search: DocumentSearch?
    /// The pane the search session started in; results show there.
    weak var searchPane: ReaderPane?
    private(set) var searchOptions = SearchOptions()
    private(set) var currentResultIndex: Int?
    private(set) var searchField: NSSearchField?
    private var searchItem: NSSearchToolbarItem?
    /// The section to go back to when a search ends.
    private var sectionBeforeSearch: SidebarSection?

    // Background work on the document's bytes (architecture §4.6)
    private(set) var renderer: PageRenderer?
    private(set) var textInventory: TextInventory?
    /// The text check in flight; replaced, and its result ignored, when the
    /// document reloads.
    private var textInventoryTask: Task<Void, Never>?
    /// When the page highlights were last replaced, to throttle them while
    /// results stream in.
    private var lastHighlightUpdate: TimeInterval = 0
    private var highlightedResultCount = 0
    private(set) var pagesWithoutText: [Int]?

    // Stored state (A2)
    /// The reader's bookmarks (A2), in reading order, stored with the document's state.
    var bookmarks: [ReaderBookmark] = [] {
        didSet {
            guard bookmarks != oldValue else { return }
            updateStoredState { $0.bookmarks = self.bookmarks }
            refreshBookmarkList()
        }
    }
    let stateStore: DocumentStateStore?
    private(set) var storedDocumentID: UUID?

    /// After a Save As, the document is the new file, with its own stored record.
    func adoptStoredDocument(_ id: UUID) {
        storedDocumentID = id
    }
    private var anchorSave: DispatchWorkItem?
    private var collapseObservation: NSKeyValueObservation?
    /// Set while the sidebar opens or closes for a reason other than the
    /// user's choice (a search showing its results, distraction-free mode),
    /// so it isn't remembered.
    var isMovingSidebarForSearch = false
    /// What distraction-free mode hid, to put back; nil while it is off. Kept for the window's
    /// life (and the session, through `SessionRestorer`).
    var distractionFree: DistractionFreeChrome?
    /// Puts the window in or out of full screen. Tests record instead of moving a window into its
    /// own Space.
    var setFullScreen: (NSWindow, Bool) -> Void = { window, on in
        if window.styleMask.contains(.fullScreen) != on { window.toggleFullScreen(nil) }
    }

    private(set) weak var readerDocument: ReaderDocument?
    private let passwordStore: any DocumentPasswordStore
    let presenter: any ReaderPresenting
    private var didCheckPasswords = false

    init(
        document: ReaderDocument,
        passwordStore: any DocumentPasswordStore = KeychainPasswordStore(),
        presenter: any ReaderPresenting = SheetPresenter(),
        stateStore: DocumentStateStore? = AppEnvironment.stateStore,
        previewPresenter: (any LinkPreviewPresenting)? = nil,
        urlOpener: (any URLOpening)? = nil,
        preferences: ReaderPreferences? = nil,
        journal: AnnotationJournal? = AppEnvironment.journal
    ) {
        self.journal = journal
        readerDocument = document
        self.passwordStore = passwordStore
        self.presenter = presenter
        self.stateStore = stateStore
        self.previewPresenter = previewPresenter ?? PopoverPreviewPresenter()
        self.urlOpener = urlOpener ?? AppEnvironment.urlOpener
        self.preferences = preferences ?? AppEnvironment.preferences
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
        // Lectern restores sessions itself (SessionRestorer); AppKit's restoration would reopen
        // the same documents a second time.
        window.isRestorable = false
        // Tests order hundreds of windows in and out; see TestWindows in AppTests.
        if AppEnvironment.isHostingTests { window.animationBehavior = .none }
        super.init(window: window)

        configure(primaryPane)
        buildContent(in: window)
        window.toolbar = makeToolbar()
        firstResponderObservation = window.observe(\.firstResponder, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.firstResponderDidChange() }
        }
        preferencesObserver = NotificationCenter.default.addObserver(
            forName: ReaderPreferences.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyPreferences() }
        }
        window.delegate = self
        showContentIfReadable()
    }

    /// Wires a pane to the window: zoom, copy, drops, the context menu,
    /// history storage, the reading position, Escape, links and focus.
    func configure(_ pane: ReaderPane) {
        let view = pane.view
        let id = pane.id
        view.onUserZoom = { [weak self] scale in self?.paneZoomDidChange(.scale(scale), in: id) }
        view.onCopyBlocked = { [weak self] in self?.explainBlocked(.copy) }
        view.onOpenFiles = { urls in ReaderDocumentController.openDocuments(at: urls) }
        view.contextMenuItems = {
            ReaderCommands.zoomItems() + [.separator()] + ReaderCommands.readingOptionItems()
        }
        view.markupColor = preferences.annotationColor
        view.onMarkupAction = { [weak self, weak pane] action in
            guard let self, let pane else { return }
            markUpSelection(action, in: pane)
        }
        view.onMarkupColor = { [weak self] preset in self?.preferences.annotationColor = preset }
        view.onAnnotationClick = { [weak self, weak pane] annotation, count in
            guard let self, let pane else { return }
            annotationClicked(annotation, clickCount: count, in: pane)
        }
        view.onAnnotationSelectionChange = { [weak self, weak pane] annotation in
            guard let self, let pane, pane === focusedPane else { return }
            annotationsSection.select(annotation.map(ObjectIdentifier.init))
        }
        view.onDeleteKey = { [weak self, weak view] in
            guard let self, let view, view.selectedAnnotation != nil else { return false }
            deleteAnnotation(nil)
            return true
        }
        view.annotationContextMenuItems = { [weak self, weak view] annotation in
            guard let self, let view else { return [] }
            return annotationMenuItems(for: annotation, in: view)
        }
        pane.onHistoryChange = { [weak self] history in
            self?.updateStoredState { $0.history[id] = history }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(pageDidChange(_:)), name: .PDFViewPageChanged, object: view)
        view.onVisibleAreaChange = { [weak self] in self?.saveAnchorSoon() }
        // Escape ends a search, then leaves distraction-free mode.
        view.onCancel = { [weak self] in
            guard let self else { return false }
            if isSearching {
                endSearch()
                return true
            }
            if isDistractionFree {
                setDistractionFree(false)
                return true
            }
            return false
        }
        view.previewsOnHover = preferences.previewsLinksOnHover
        pane.onExternalLink = { [weak self] target in self?.handleExternalLink(target) }
        view.onPreviewLink = { [weak self, weak pane] request in
            guard let self, let pane else { return }
            showPreview(request, from: pane)
        }
        view.onHighlightedLinkChange = { [weak self, weak pane] target in
            guard let self, let pane else { return }
            paneContainers[pane.id]?.showLinkStatus(target)
            if target == nil { hoverLinkDidEnd(in: pane) }
        }
        let container = PaneContainerView(pdfView: view)
        container.onClose = { [weak self] in self?.closePane(id) }
        paneContainers[id] = container
    }

    private func applyPreferences() {
        for pane in panes {
            pane.view.previewsOnHover = preferences.previewsLinksOnHover
            pane.view.markupColor = preferences.annotationColor
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Sidebar and reading area side by side, in a split view whose sidebar
    /// collapses (spec §4.1). The reading area holds a second split view for
    /// the panes (B3).
    private func buildContent(in window: NSWindow) {
        let reading = NSViewController()
        let container = NSView()
        readingSplit.splitView.isVertical = true
        readingSplit.splitView.dividerStyle = .thin
        readingSplit.addSplitViewItem(paneItem(for: primaryPane))
        reading.addChild(readingSplit)
        let panesView = readingSplit.view
        container.addSubview(panesView)
        panesView.translatesAutoresizingMaskIntoConstraints = false
        notice.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(notice)
        formInfoLine.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(formInfoLine)
        NSLayoutConstraint.activate([
            panesView.topAnchor.constraint(equalTo: container.topAnchor),
            panesView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            panesView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            panesView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            notice.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 12),
            notice.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            notice.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -40),
            formInfoLine.bottomAnchor.constraint(equalTo: container.safeAreaLayoutGuide.bottomAnchor, constant: -10),
            formInfoLine.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            formInfoLine.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -40),
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
        sidebar.onSectionChange = { [weak self] section in
            // Search results come and go with the search; they are never the
            // section to reopen on.
            if section != .search { self?.settings.sidebar.section = section }
            if section == .annotations { self?.refreshAnnotationList() }
        }
        annotationsSection.onSelect = { [weak self] item in self?.jumpToListItem(item) }
        bookmarksSection.onSelect = { [weak self] id in self?.jumpToBookmark(id) }
        bookmarksSection.onRename = { [weak self] id in self?.renameBookmark(id) }
        bookmarksSection.onRemove = { [weak self] id in self?.removeBookmark(id) }
        outlineSection.onJump = { [weak self] outline in self?.jump(to: outline) }
        thumbnailsSection.onJump = { [weak self] index in self?.pane.jump(toPageAt: index) }
        searchSection.onShowResult = { [weak self] index in self?.showResult(at: index) }
        collapseObservation = sidebarItem.observe(\.isCollapsed, options: [.new]) { [weak self] item, _ in
            let collapsed = item.isCollapsed
            MainActor.assumeIsolated { self?.sidebarCollapsedDidChange(collapsed) }
        }
    }

    /// Set for windows a session restore reopens: they ask for a password (or read the Keychain)
    /// only when they become key, one at a time, never all at once at launch.
    var defersPasswordCheckUntilKey = false

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        if !defersPasswordCheckUntilKey { checkPasswordsIfNeeded() }
    }

    // Restored windows can come back without showWindow; checking when the
    // window first becomes key covers them.
    func windowDidBecomeKey(_ notification: Notification) {
        checkPasswordsIfNeeded()
    }

    /// True once the pages are on screen (the document is unlocked).
    var isShowingContent: Bool { primaryPane.view.document != nil }

    private func showContentIfReadable() {
        guard !isShowingContent, let readerDocument, !readerDocument.isPasswordLocked,
              let pdf = readerDocument.pdfDocument
        else { return }
        let stored = openStoredState(for: readerDocument, pdf: pdf)
        readerDocument.applyViewRotation(settings.rotation)
        primaryPane.view.show(pdf)
        primaryPane.view.apply(settings, hints: readerDocument.layoutHints)
        // Restore once the view has its real size; the anchor then holds
        // through any later resize until the user scrolls. A document seen
        // for the first time starts at the top of page 1, below the toolbar.
        splitViewController.view.layoutSubtreeIfNeeded()
        if let anchor = stored?.anchor ?? primaryPane.view.topAnchor(forPageAt: 0) {
            primaryPane.view.restore(anchor)
        }
        if let split = stored?.split {
            restoreSplit(split, history: stored?.history[.secondary])
        }
        configureSidebar(for: readerDocument, pdf: pdf)
        window?.makeFirstResponder(focusedPane.view)
        annotationEditorDidChange()
        readerDocument.inspectForAnnotations()
        // In the background: which pages have no text, for search (B8) and VoiceOver (spec §9.3).
        loadTextInventoryIfNeeded()
    }

    // MARK: Stored state (A2)

    /// Loads what was remembered about this file: the view settings, the
    /// sidebar, the pane's history and the reading position. Documents
    /// without a file (tests) have nothing stored.
    private func openStoredState(for document: ReaderDocument, pdf: PDFDocument) -> DocumentState? {
        guard let stateStore, let url = document.fileURL else { return nil }
        let identifiers = pdf.documentRef.map(DocumentIdentity.fileIdentifiers(of:))
        let stored = stateStore.open(url: url, data: document.originalData, pageCount: pdf.pageCount, fileIdentifiers: identifiers)
        storedDocumentID = stored.id
        var restored = stored.state.viewSettings
        if stored.match == .new, pdf.outlineRoot.map({ $0.numberOfChildren > 0 }) == true {
            // A document with a table of contents opens the sidebar on it.
            restored.sidebar.section = .outline
        }
        settings = restored
        primaryPane.setHistory(stored.state.history[.primary] ?? HistoryStack())
        // As stored: clamped only where shown or followed, so nothing is lost if the file grows back.
        bookmarks = ReaderBookmarks.sorted(stored.state.bookmarks)
        return stored.state
    }

    func updateStoredState(_ change: (inout DocumentState) -> Void) {
        guard let stateStore, let storedDocumentID else { return }
        stateStore.update(storedDocumentID, change)
    }

    /// Scrolling never makes a history entry, but the reading position is
    /// remembered a moment after it settles.
    func saveAnchorSoon() {
        guard storedDocumentID != nil else { return }
        anchorSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveAnchor() }
        }
        anchorSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Remembers each pane's place, and the split (B3).
    func saveAnchor() {
        anchorSave?.cancel()
        anchorSave = nil
        guard isShowingContent, let anchor = primaryPane.view.currentAnchor else { return }
        let split = secondaryPane.map {
            SplitState(secondaryAnchor: $0.view.currentAnchor, focusedPane: focusedPaneID, secondaryZoom: $0.view.zoomMode)
        }
        updateStoredState {
            $0.anchor = anchor
            $0.split = split
        }
    }

    /// Saves the reading position and writes everything out now: the window
    /// is closing or the app is quitting.
    func saveStateNow() {
        saveAnchor()
        stateStore?.flush()
    }

    func windowWillClose(_ notification: Notification) {
        for pane in panes { pane.view.outliveQueuedPDFKitWork() }
        saveStateNow()
        search?.cancel()
        dismissPreview()
    }

    // MARK: Sidebar (spec §4.1)

    func configureSidebar(for document: ReaderDocument, pdf: PDFDocument) {
        // Both open their own copy of the document lazily, on their actor.
        renderer = PageRenderer(data: document.originalData, password: document.sessionPassword)
        textInventoryTask?.cancel()
        textInventoryTask = nil
        textInventory = TextInventory(data: document.originalData, password: document.sessionPassword)
        pagesWithoutText = nil
        outlineSection.setDocument(pdf)
        thumbnailsSection.configure(
            document: pdf,
            renderer: renderer,
            label: { [weak document] index in document?.label(forPageAt: index) ?? String(index + 1) },
            rotation: settings.rotation
        )
        sidebar.show(settings.sidebar.section)
        sidebarItem.isCollapsed = !settings.sidebar.isVisible
        updateThumbnailSelection()
        refreshBookmarkList()
        if settings.sidebar.section == .annotations, settings.sidebar.isVisible { refreshAnnotationList() }
    }

    /// The thumbnails mark the focused pane's page.
    func updateThumbnailSelection() {
        guard let document = pdfView.document, let page = pdfView.currentPage else { return }
        thumbnailsSection.setCurrentPage(document.index(for: page))
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

    /// Shows a section and moves keyboard focus into it, so the outline or
    /// thumbnails can be used from the keyboard.
    func showSidebarSection(_ section: SidebarSection) {
        if section == .annotations { refreshAnnotationList() }
        sidebar.show(section)
        if section != .search { settings.sidebar.section = section }
        setSidebarVisible(true)
        sidebar.focusVisibleSection()
    }

    private func sidebarCollapsedDidChange(_ collapsed: Bool) {
        // Dragging the divider closed counts as hiding it.
        if !isMovingSidebarForSearch, settings.sidebar.isVisible == collapsed, isShowingContent {
            settings.sidebar.isVisible = !collapsed
        }
    }

    @objc private func pageDidChange(_ notification: Notification) {
        guard (notification.object as? ReaderPDFView) === pdfView else { return }
        updateThumbnailSelection()
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
        // The search field lives in the toolbar.
        if isDistractionFree { setDistractionFree(false) }
        if let toolbar = window.toolbar {
            if !toolbar.isVisible { toolbar.isVisible = true }
            // A customised toolbar may have lost the field; ⌘F brings it back.
            if !toolbar.items.contains(where: { $0.itemIdentifier == .search }) {
                toolbar.insertItem(withItemIdentifier: .search, at: toolbar.items.count)
            }
        }
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
            searchPane = pane
            pane.beginSearchSession()
            let search = DocumentSearch(document: document)
            search.colouredResultLimit = SearchResultsSectionViewController.rowLimit
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
        let searchPane = searchPane ?? pane
        self.searchPane = nil
        searchPane.endSearchSession()
        searchPane.view.highlightedSelections = nil
        highlightedResultCount = 0
        searchPane.view.clearSelection()
        searchSection.setSearch(nil, numbering: PageNumbering(pageCount: 0))
        if searchField?.stringValue.isEmpty == false { searchField?.stringValue = "" }
        sidebar.setHidden(true, for: .search)
        sidebar.show(sectionBeforeSearch ?? settings.sidebar.section)
        setSidebarCollapsedForSearch(!settings.sidebar.isVisible)
        sectionBeforeSearch = nil
    }

    private func setSidebarCollapsedForSearch(_ collapsed: Bool) {
        isMovingSidebarForSearch = true
        sidebarItem.isCollapsed = collapsed || isDistractionFree
        isMovingSidebarForSearch = false
    }

    var isSearching: Bool { search != nil }

    override func cancelOperation(_ sender: Any?) {
        if isSearching {
            endSearch()
        } else if isDistractionFree {
            setDistractionFree(false)
        }
    }

    private func searchDidChange() {
        searchSection.reload()
        guard let search else { return }
        // Replacing thousands of highlights is costly: do it when the count
        // changed, at most twice a second while results stream in, and once
        // more when the search ends.
        let shown = min(search.results.count, SearchResultsSectionViewController.rowLimit)
        let now = ProcessInfo.processInfo.systemUptime
        guard shown != highlightedResultCount,
              !search.isSearching || shown == 0 || now - lastHighlightUpdate >= 0.5
        else { return }
        lastHighlightUpdate = now
        highlightedResultCount = shown
        (searchPane ?? pane).view.highlightedSelections = shown == 0 ? nil : search.results.prefix(shown).map(\.selection)
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
        // Past the coloured ones (DocumentSearch.colouredResultLimit), coloured when shown.
        results[index].selection.color = .findHighlightColor
        (searchPane ?? pane).show(results[index].selection)
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

    func loadTextInventoryIfNeeded() {
        guard pagesWithoutText == nil, textInventoryTask == nil, let textInventory else { return }
        textInventoryTask = Task { [weak self] in
            let missing = await textInventory.pagesWithoutText()
            self?.storeTextInventory(missing, from: textInventory)
        }
    }

    /// Keeps a text check's result only if it is about the document showing
    /// now: a check started before a reload finishes about the old file.
    private func storeTextInventory(_ missing: [Int], from inventory: TextInventory) {
        guard !Task.isCancelled, inventory === textInventory else { return }
        textInventoryTask = nil
        pagesWithoutText = missing
        search?.pagesWithoutText = missing.count
        for pane in panes { applyTextAccessibility(to: pane) }
    }

    /// Scanned pages aren't presented as readable text (spec §9.3): the reading view's
    /// accessibility help says how many pages are only images, and the pane's value says so in
    /// short. PDFKit exposes no per-page accessibility to change, so this is per document.
    func applyTextAccessibility(to pane: ReaderPane) {
        let pageCount = pane.view.document?.pageCount ?? 0
        let missing = pagesWithoutText?.count ?? 0
        let help: String?
        let value: String?
        if pageCount == 0 || missing == 0 {
            help = nil
            value = nil
        } else if missing >= pageCount {
            help = "This document has no text that VoiceOver can read. Its pages are images, such as scans."
            value = "No readable text"
        } else {
            help = "\(missing) of \(pageCount) pages have no text that VoiceOver can read. They are images, such as scans."
            value = "Some pages have no readable text"
        }
        pane.view.setAccessibilityHelp(help)
        paneContainers[pane.id]?.readableTextNote = value
    }

    /// Waits for the text check in flight, for tests.
    func waitForTextInventory() async {
        if textInventoryTask == nil { loadTextInventoryIfNeeded() }
        await textInventoryTask?.value
    }

    // MARK: Changes on disk (B7)

    /// The document reloaded silently: keep the reader's place, the history
    /// (clamped to the new page count) and any search, then say so briefly.
    func documentDidReload() {
        guard let readerDocument else { return }
        dismissPreview()
        let anchors = panes.map { ($0, $0.view.currentAnchor) }
        let query = search?.query
        let queryPane = searchPane
        if isSearching {
            search?.cancel()
            search = nil
            for pane in panes { pane.view.highlightedSelections = nil }
            highlightedResultCount = 0
        }
        guard let pdf = readerDocument.pdfDocument, !readerDocument.isPasswordLocked else {
            // The new file needs a password the old one didn't.
            if isSplit { closePane(.secondary) }
            primaryPane.view.show(nil)
            didCheckPasswords = false
            checkPasswordsIfNeeded()
            return
        }
        readerDocument.applyViewRotation(settings.rotation)
        refreshBookmarkList()
        for (pane, anchor) in anchors {
            pane.setHistory(pane.history.clamped(toPageCount: pdf.pageCount))
            var paneSettings = settings
            paneSettings.zoom = pane.view.zoomMode
            pane.view.show(pdf)
            pane.view.apply(paneSettings, hints: readerDocument.layoutHints)
            if let anchor { pane.view.restore(anchor.clamped(toPageCount: pdf.pageCount)) }
        }
        searchPane = queryPane
        annotationEditorDidChange()
        configureSidebar(for: readerDocument, pdf: pdf)
        refreshStoredIdentity()
        if let storedDocumentID {
            // A journal not yet offered (the file changed while the background check was still
            // running) is set aside, to be offered as no longer fitting. Only a journal of this
            // session's own changes, superseded by the reload, is deleted. A reload to a file that
            // needs a password returns above and leaves the journal for the check after unlocking.
            if didCheckJournal { journal?.remove(storedDocumentID) } else { journal?.setAside(storedDocumentID) }
        }
        readerDocument.inspectForAnnotations()
        if let query, !query.isEmpty {
            // Same session: no new history entry.
            let search = DocumentSearch(document: pdf)
            search.colouredResultLimit = SearchResultsSectionViewController.rowLimit
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
        // NSDocument may not have updated fileURL yet; the new URL is known.
        refreshStoredIdentity(at: url)
    }

    func refreshStoredIdentity(at newURL: URL? = nil) {
        guard let stateStore, let storedDocumentID, let readerDocument, let url = newURL ?? readerDocument.fileURL,
              let pdf = readerDocument.pdfDocument
        else { return }
        let identity = stateStore.identity(
            for: url, data: readerDocument.originalData, pageCount: pdf.pageCount,
            fileIdentifiers: pdf.documentRef.map(DocumentIdentity.fileIdentifiers(of:))
        )
        stateStore.update(storedDocumentID) { $0.identity = identity }
    }

    func hideFileRemovedNotice() {
        notice.hide()
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
        var stepped = settings
        stepped.zoomIn(from: pdfView.scaleFactor)
        setZoom(stepped.zoom)
    }

    @objc func decreaseZoom(_ sender: Any?) {
        var stepped = settings
        stepped.zoomOut(from: pdfView.scaleFactor)
        setZoom(stepped.zoom)
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

    var layoutHints: DocumentLayoutHints { readerDocument?.layoutHints ?? .none }

    func preservingEveryAnchor(_ panes: ArraySlice<ReaderPane>, _ body: () -> Void) {
        guard let first = panes.first else {
            body()
            return
        }
        first.view.preservingAnchor { preservingEveryAnchor(panes.dropFirst(), body) }
    }

    /// Zoom acts on the focused pane only; each pane keeps its own.
    private func setZoom(_ mode: ZoomMode) {
        pdfView.setZoomMode(mode)
        paneZoomDidChange(mode, in: focusedPaneID)
    }

    /// The first pane's zoom is the document's `ViewSettings.zoom`; the
    /// second pane's is stored with the split.
    func paneZoomDidChange(_ mode: ZoomMode, in id: PaneID) {
        if id == .primary {
            settings.zoom = mode
        } else {
            saveAnchorSoon()
        }
    }

    /// Applies a layout or rotation change to every pane, keeping each
    /// pane's place (A3). Rotation lives in the shared model, so it is
    /// applied once, inside every pane's anchor capture. Each pane keeps
    /// its own zoom.
    private func updateLayout(_ change: (inout ViewSettings) -> Void) {
        let rotation = settings.rotation
        change(&settings)
        preservingEveryAnchor(panes[...]) {
            if settings.rotation != rotation {
                readerDocument?.applyViewRotation(settings.rotation)
            }
            for pane in panes {
                if settings.rotation != rotation { pane.view.layoutDocumentView() }
                var paneSettings = settings
                paneSettings.zoom = pane.view.zoomMode
                pane.view.apply(paneSettings, hints: layoutHints)
            }
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
        case #selector(focusOtherPane(_:)), #selector(closeFocusedPane(_:)): return isSplit
        case #selector(highlightSelection(_:)), #selector(underlineSelection(_:)), #selector(strikeThroughSelection(_:)), #selector(commentOnSelection(_:)):
            return pdfView.currentSelection?.string?.isEmpty == false
        case #selector(deleteAnnotation(_:)):
            // A bare ⌫ must reach text fields: only enabled while the page has focus.
            return selectedAnnotation != nil && window?.firstResponder === pdfView
        case #selector(editAnnotationText(_:)):
            return selectedAnnotation != nil
        case #selector(exportBookmarks(_:)): return !bookmarks.isEmpty
        case #selector(renameBookmarkMenu(_:)): return bookmarkToRename != nil
        default: return true
        }
    }

    private func isChecked(_ action: Selector?) -> Bool {
        switch action {
        case #selector(zoomToActualSize(_:)): pdfView.zoomMode == .actualSize
        case #selector(zoomToFitPage(_:)): pdfView.zoomMode == .fitPage
        case #selector(zoomToFitWidth(_:)): pdfView.zoomMode == .fitWidth
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
        case #selector(togglePreviewLinksOnHover(_:)): preferences.previewsLinksOnHover
        case #selector(focusLinks(_:)): pdfView.isLinkFocusActive
        case #selector(setAnnotationColor(_:)): false
        case #selector(showAnnotationList(_:)): isSidebarVisible && sidebar.visibleSection == .annotations
        case #selector(showBookmarkList(_:)): isSidebarVisible && sidebar.visibleSection == .bookmarks
        default: false
        }
    }
}

extension ReaderWindowController: NSWindowDelegate {
    /// The document's undo manager, so annotation undo follows the document (B4).
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        readerDocument?.undoManager
    }
}

extension ReaderWindowController: NSMenuItemValidation, NSToolbarItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleReaderSidebar(_:)) {
            menuItem.title = isSidebarVisible ? "Hide Sidebar" : "Show Sidebar"
        }
        if menuItem.action == #selector(toggleBookmark(_:)) {
            menuItem.title = hasBookmarkHere ? "Remove Bookmark" : "Add Bookmark"
        }
        if menuItem.action == #selector(toggleDistractionFree(_:)) {
            menuItem.title = isDistractionFree ? "Exit Distraction-Free Mode" : "Enter Distraction-Free Mode"
        }
        if menuItem.action == #selector(toggleSplitView(_:)) {
            menuItem.title = isSplit ? "Close Split View" : "Split View"
        }
        if menuItem.action == #selector(setAnnotationColor(_:)) {
            let current = selectedAnnotation.map { AnnotationEditor.rgb(of: $0) }.flatMap { AnnotationColorPreset.matching(red: $0.red, green: $0.green, blue: $0.blue) }
                ?? (selectedAnnotation == nil ? markupColor : nil)
            menuItem.state = AnnotationColorPreset.allCases.firstIndex(of: current ?? .default) == menuItem.tag && current != nil ? .on : .off
            if let selected = selectedAnnotation {
                return isShowingContent && AnnotationKindName.allowsColorChange(subtype: selected.type ?? "")
            }
            return isShowingContent
        }
        if menuItem.action == #selector(editAnnotationText(_:)) {
            menuItem.title = selectedAnnotation?.type == "Text" ? "Edit Note…" : (selectedAnnotation == nil ? "Edit Note or Comment…" : "Edit Comment…")
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

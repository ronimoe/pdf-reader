import AppKit
import PDFKit
import Persistence
import ReaderCore
import ReaderKit

// MARK: Split view and focus (B3)

extension ReaderWindowController {
    /// A split item holding a pane's container.
    func paneItem(for pane: ReaderPane) -> NSSplitViewItem {
        let controller = NSViewController()
        controller.view = paneContainers[pane.id] ?? PaneContainerView(pdfView: pane.view)
        let item = NSSplitViewItem(viewController: controller)
        item.minimumThickness = 220
        item.holdingPriority = .defaultLow
        return item
    }

    func pane(_ id: PaneID) -> ReaderPane? {
        id == .primary ? primaryPane : (id == .secondary ? secondaryPane : nil)
    }

    /// The pane that isn't `pane`, while split.
    func otherPane(than pane: ReaderPane) -> ReaderPane? {
        guard let secondaryPane else { return nil }
        return pane === primaryPane ? secondaryPane : primaryPane
    }

    /// Focus follows the first responder: a click or a key in a pane focuses it.
    func firstResponderDidChange() {
        guard let responder = window?.firstResponder as? NSView else { return }
        for pane in panes where responder === pane.view || responder.isDescendant(of: pane.view) {
            setFocusedPane(pane.id)
        }
    }

    func setFocusedPane(_ id: PaneID) {
        let id = pane(id) == nil ? .primary : id
        guard id != focusedPaneID else {
            updatePaneChrome()
            return
        }
        focusedPaneID = id
        updatePaneChrome()
        updateThumbnailSelection()
        saveAnchorSoon()
    }

    /// The focus bar on the focused pane and close buttons, while split.
    func updatePaneChrome() {
        for pane in panes {
            let name = pane.id == .primary ? "Left" : "Right"
            paneContainers[pane.id]?.setSplitChrome(isSplit: isSplit, isFocused: pane.id == focusedPaneID, name: name)
        }
    }

    /// Splits the tab. The new pane shares the document, takes the
    /// layout, and starts at `anchor` (or where the focused pane is) with
    /// an empty history. Focus stays where it was.
    @discardableResult
    func openSplit(at anchor: ReadingAnchor? = nil) -> ReaderPane? {
        if let secondaryPane { return secondaryPane }
        guard isShowingContent, let document = primaryPane.view.document else { return nil }
        let pane = ReaderPane(id: .secondary)
        configure(pane)
        secondaryPane = pane
        let item = paneItem(for: pane)
        readingSplit.addSplitViewItem(item)
        var paneSettings = settings
        paneSettings.zoom = focusedPane.view.zoomMode
        pane.view.document = document
        pane.view.apply(paneSettings, hints: layoutHints)
        equalizePanes()
        let start = anchor ?? focusedPane.view.currentAnchor
        if let start { pane.view.restore(start) }
        updatePaneChrome()
        saveAnchor()
        return pane
    }

    /// Two equal panes (B3).
    func equalizePanes() {
        splitViewController.view.layoutSubtreeIfNeeded()
        let splitView = readingSplit.splitView
        guard splitView.subviews.count == 2 else { return }
        let width = splitView.bounds.width - splitView.dividerThickness
        splitView.setPosition((width / 2).rounded(), ofDividerAt: 0)
        splitView.layoutSubtreeIfNeeded()
    }

    /// Restores a stored split: the second pane's place and history, and focus.
    func restoreSplit(_ split: SplitState, history: HistoryStack?) {
        guard let pane = openSplit(at: split.secondaryAnchor) else { return }
        if let anchor = split.secondaryAnchor { pane.view.restore(anchor) }
        pane.setHistory(history ?? HistoryStack())
        setFocusedPane(split.focusedPane)
    }

    /// Closes a pane. Closing the first pane moves the second one's place,
    /// zoom and history into it, so the pane that stays is always `.primary`.
    func closePane(_ id: PaneID) {
        guard let secondary = secondaryPane else { return }
        dismissPreview()
        let closingSearchPane = (id == .primary ? primaryPane : secondary) === searchPane
        if closingSearchPane { endSearch() }
        if id == .primary {
            let anchor = secondary.view.currentAnchor
            primaryPane.setHistory(secondary.history)
            primaryPane.view.setZoomMode(secondary.view.zoomMode)
            if let anchor { primaryPane.view.restore(anchor) }
        }
        secondary.view.endLinkFocus()
        if let item = readingSplit.splitViewItems.first(where: { $0.viewController.view === paneContainers[.secondary] }) {
            readingSplit.removeSplitViewItem(item)
        }
        NotificationCenter.default.removeObserver(self, name: .PDFViewPageChanged, object: secondary.view)
        secondary.view.document = nil
        secondaryPane = nil
        paneContainers[.secondary] = nil
        focusedPaneID = .primary
        splitViewController.view.layoutSubtreeIfNeeded()
        if let anchor = primaryPane.view.currentAnchor { primaryPane.view.restore(anchor) }
        updatePaneChrome()
        updateThumbnailSelection()
        window?.makeFirstResponder(primaryPane.view)
        updateStoredState { $0.history[.secondary] = nil }
        saveAnchor()
    }

    /// View ▸ Split View: opens a second pane at the same place, or closes
    /// the pane that isn't focused.
    @objc func toggleSplitView(_ sender: Any?) {
        if isSplit {
            closePane(focusedPaneID == .primary ? .secondary : .primary)
        } else {
            openSplit()
        }
    }

    @objc func closeFocusedPane(_ sender: Any?) {
        closePane(focusedPaneID)
    }

    @objc func focusOtherPane(_ sender: Any?) {
        guard let other = otherPane(than: focusedPane) else { return }
        window?.makeFirstResponder(other.view)
        setFocusedPane(other.id)
    }

    /// Open in Split (B3): creates the split at the destination, or moves the
    /// other pane there, recording the move in that pane's own history.
    func openInSplit(_ destination: PDFDestination, from source: ReaderPane) {
        if let other = otherPane(than: source) {
            other.jump(to: destination)
        } else if let anchor = source.view.anchor(for: destination) {
            openSplit(at: anchor)
        }
        saveAnchor()
    }

    // MARK: Annotation changes (M0b Q7)

    /// Call after any annotation add, edit or delete made through `source`.
    /// A live change shows only in the view that last laid the page out, so
    /// every other pane re-assigns its document and keeps its place. If the
    /// source isn't the page's owner it re-binds too.
    func notifyAnnotationsChanged(from source: ReaderPane, pages: [PDFPage] = []) {
        for pane in panes where pane !== source {
            pane.view.rebindDocument()
        }
        // Re-binding the other panes moved page ownership to them; give it
        // back to the source by re-binding it last, so the next change made
        // there shows there at once.
        if isSplit { source.view.rebindDocument() }
    }
}

// MARK: Links (A3, A4)

extension ReaderWindowController {
    /// Web links open in the default browser, other schemes ask first, and
    /// GoToR, Launch, SubmitForm and JavaScript are explained and never
    /// performed.
    func handleExternalLink(_ target: LinkTarget) {
        switch target {
        case let .web(url):
            urlOpener.open(url)
        case let .otherScheme(url):
            guard let window else { return }
            let opener = urlOpener
            presenter.confirmOpening(url, on: window) { opener.open(url) }
        case let .blocked(type):
            guard let window else { return }
            presenter.explainBlockedLink(BlockedLink(actionType: type), on: window)
        case .destination, .named:
            break
        }
    }

    /// Shows the preview for an internal link. The source pane's place
    /// never changes unless the user chooses Go.
    func showPreview(_ request: LinkPreviewRequest, from source: ReaderPane) {
        guard let document = source.view.document, source.view.window != nil else { return }
        dismissPreview()
        let preview = LinkPreviewController(document: document, destination: request.destination, linkText: request.linkText, trigger: request.trigger)
        preview.onGo = { [weak source] destination in source?.jump(to: destination) }
        preview.onOpenInSplit = { [weak self, weak source] destination in
            guard let self, let source else { return }
            openInSplit(destination, from: source)
        }
        preview.onExternalLink = { [weak self] target in self?.handleExternalLink(target) }
        preview.onDismissRequest = { [weak self, weak preview] in
            guard let self, let preview else { return }
            previewPresenter.dismiss(preview)
        }
        preview.onClose = { [weak self, weak preview] in
            guard let self, linkPreview === preview else { return }
            linkPreview = nil
            linkPreviewSource = nil
            if let window, window.isKeyWindow || window.firstResponder == nil { window.makeFirstResponder(source.view) }
        }
        linkPreview = preview
        linkPreviewSource = source
        previewPresenter.present(preview, relativeTo: request.sourceRect, of: source.view)
    }

    func dismissPreview() {
        hoverDismissTimer?.invalidate()
        hoverDismissTimer = nil
        guard let preview = linkPreview else { return }
        previewPresenter.dismiss(preview)
        linkPreview = nil
        linkPreviewSource = nil
    }

    /// The pointer left a link. A preview it opened on hover closes shortly
    /// after, unless the pointer went into the preview.
    func hoverLinkDidEnd(in pane: ReaderPane) {
        guard let preview = linkPreview, preview.trigger == .hover, linkPreviewSource === pane else { return }
        hoverDismissTimer?.invalidate()
        let timer = Timer(timeInterval: 0.4, repeats: false) { [weak self, weak preview] _ in
            MainActor.assumeIsolated {
                guard let self, let preview, self.linkPreview === preview, !preview.pointerHasEntered else { return }
                self.dismissPreview()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverDismissTimer = timer
    }

    /// View ▸ Focus Links (⌥Tab): keyboard link focus in the focused pane.
    @objc func focusLinks(_ sender: Any?) {
        guard isShowingContent else { return }
        window?.makeFirstResponder(pdfView)
        pdfView.toggleLinkFocus()
    }

    @objc func togglePreviewLinksOnHover(_ sender: Any?) {
        preferences.previewsLinksOnHover.toggle()
    }
}

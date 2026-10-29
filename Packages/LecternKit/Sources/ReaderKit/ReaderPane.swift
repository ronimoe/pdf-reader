import AppKit
import PDFKit
import ReaderCore

/// One reading pane: a `ReaderPDFView` with its own identity and history
/// (B2, architecture §4.2). A tab has one pane until the split view lands in
/// M3; the sidebar and search act on the focused one.
///
/// Every jump goes through the pane, so it is recorded exactly once: outline,
/// thumbnail and go-to-page jumps, links PDFKit follows, and the first search
/// result of a session. Scrolling is never recorded.
public final class ReaderPane {
    public let id: PaneID
    public let view: ReaderPDFView
    public private(set) var history: HistoryStack {
        didSet {
            if history != oldValue { onHistoryChange?(history) }
        }
    }

    /// Called whenever the history changes, to store it (A2).
    public var onHistoryChange: ((HistoryStack) -> Void)?

    public init(id: PaneID, view: ReaderPDFView = ReaderPDFView(frame: .zero), history: HistoryStack = HistoryStack()) {
        self.id = id
        self.view = view
        self.history = history
        view.onLinkJump = { [weak self] departure in
            self?.history.recordJump(from: departure)
        }
        view.onNamedHistoryAction = { [weak self] forward in
            if forward { self?.goForward() } else { self?.goBack() }
        }
    }

    /// Replaces the history, for instance with the stored one.
    public func setHistory(_ history: HistoryStack) {
        self.history = history
    }

    public var currentAnchor: ReadingAnchor? { view.currentAnchor }

    // MARK: Jumps

    /// Jumps to `anchor` and records where reading was.
    public func jump(to anchor: ReadingAnchor) {
        if let departure = view.currentAnchor { history.recordJump(from: departure) }
        view.restore(anchor)
    }

    public func jump(to destination: PDFDestination) {
        guard let anchor = view.anchor(for: destination) else { return }
        jump(to: anchor)
    }

    public func jump(toPageAt index: Int) {
        guard let anchor = view.topAnchor(forPageAt: index) else { return }
        jump(to: anchor)
    }

    // MARK: Back and forward

    public var canGoBack: Bool { history.canGoBack && view.document != nil }
    public var canGoForward: Bool { history.canGoForward && view.document != nil }

    public func goBack() {
        guard let current = view.currentAnchor, let target = history.goBack(from: current) else { return }
        view.restore(target)
    }

    public func goForward() {
        guard let current = view.currentAnchor, let target = history.goForward(from: current) else { return }
        view.restore(target)
    }

    // MARK: Search sessions (B2)

    /// Marks where reading was as a search starts.
    public func beginSearchSession() {
        guard let current = view.currentAnchor else { return }
        history.beginSearchSession(at: current)
    }

    public func endSearchSession() {
        history.endSearchSession()
    }

    /// Shows a search result: selects and scrolls to it. Only the first
    /// result of a session adds a history entry.
    public func show(_ selection: PDFSelection) {
        if let current = view.currentAnchor {
            history.willShowSearchResult(from: current)
        }
        view.setCurrentSelection(selection, animate: false)
        view.reveal(selection)
    }
}

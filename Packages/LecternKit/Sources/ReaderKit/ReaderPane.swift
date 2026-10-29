import AppKit
import PDFKit
import ReaderCore

/// One reading pane: a `ReaderPDFView` with its own identity and history
/// (B2, architecture §4.2). A tab has one pane, or two when split (B3); the
/// sidebar and search act on the focused one.
///
/// Every jump goes through the pane, so it is recorded exactly once: outline,
/// thumbnail and go-to-page jumps, followed links, a preview's Go, and the
/// first search result of a session. Scrolling is never recorded.
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
    /// Called for links that leave the document or are blocked (web, other
    /// schemes, GoToR, Launch…), for the window to open, confirm or explain.
    /// Internal links and page actions the pane follows itself.
    public var onExternalLink: ((LinkTarget) -> Void)?

    public init(id: PaneID, view: ReaderPDFView = ReaderPDFView(frame: .zero), history: HistoryStack = HistoryStack()) {
        self.id = id
        self.view = view
        self.history = history
        view.onActivateLink = { [weak self] target in self?.follow(target) }
    }

    // MARK: Links (A3, A4)

    /// Follows a link: internal destinations and page actions jump here and
    /// make a history entry; everything else goes to the window.
    public func follow(_ target: LinkTarget) {
        switch target {
        case let .destination(destination):
            jump(to: destination)
        case let .named(name):
            followNamed(name)
        case .web, .otherScheme, .blocked:
            onExternalLink?(target)
        }
    }

    private func followNamed(_ name: PDFActionNamedName) {
        guard let document = view.document, document.pageCount > 0 else { return }
        let current = view.currentAnchor?.pageIndex ?? 0
        switch name {
        case .goBack: goBack()
        case .goForward: goForward()
        case .nextPage: jump(toPageAt: min(current + 1, document.pageCount - 1))
        case .previousPage: jump(toPageAt: max(current - 1, 0))
        case .firstPage: jump(toPageAt: 0)
        case .lastPage: jump(toPageAt: document.pageCount - 1)
        default:
            // Print, Find, Zoom…: viewer commands a document can't trigger.
            NSSound.beep()
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

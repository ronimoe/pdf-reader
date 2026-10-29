import AppKit

/// The app's side of session restore and the empty state, as a unit tests can drive: when the
/// session is restored, saved and left alone, and when the empty state shows. `AppDelegate` and
/// `ReaderDocumentController` only forward their events here.
final class SessionCoordinator {
    /// Nil while hosting tests (and then nothing is restored or saved).
    let restorer: SessionRestorer?
    private let emptyStateDidChange: (Int) -> Void
    private let showEmptyState: () -> Void
    private let hideEmptyState: () -> Void
    private let documentCount: () -> Int
    private let anyWindowVisible: () -> Bool
    /// True from launch until last session's documents have reopened: the empty state doesn't
    /// flash up first, and the session file isn't rewritten with half of it (a crash or a quit
    /// mid-restore must not lose the rest).
    private(set) var isRestoring = false
    private var emptyStateWanted = false

    init(
        restorer: SessionRestorer?,
        emptyStateDidChange: @escaping (Int) -> Void,
        showEmptyState: @escaping () -> Void,
        hideEmptyState: @escaping () -> Void,
        documentCount: @escaping () -> Int = { NSDocumentController.shared.documents.count },
        anyWindowVisible: @escaping () -> Bool = { NSApp.windows.contains(where: \.isVisible) }
    ) {
        self.restorer = restorer
        self.emptyStateDidChange = emptyStateDidChange
        self.showEmptyState = showEmptyState
        self.hideEmptyState = hideEmptyState
        self.documentCount = documentCount
        self.anyWindowVisible = anyWindowVisible
    }

    /// At launch: reopens last session if there is one to reopen. Returns the restore's task.
    @discardableResult
    func launch() -> Task<Void, Never>? {
        guard let restorer, restorer.shouldRestore, restorer.load()?.windows.isEmpty == false else { return nil }
        beginRestoring()
        return Task { @MainActor in
            await restorer.restore()
            finishRestoring()
        }
    }

    func beginRestoring() {
        isRestoring = true
    }

    func finishRestoring() {
        isRestoring = false
        let count = documentCount()
        if count == 0, emptyStateWanted || !anyWindowVisible() {
            showEmptyState()
        } else if count > 0 {
            hideEmptyState()
        }
        emptyStateWanted = false
        restorer?.documentsDidChange()
    }

    /// A document opened or closed.
    func documentsDidChange(count: Int) {
        guard !isRestoring else { return }
        emptyStateDidChange(count)
        restorer?.documentsDidChange()
    }

    /// AppKit asks for an untitled document (launch, or a Dock click with no windows).
    func openUntitled() {
        if isRestoring {
            // Shown after the restore, only if nothing came back.
            emptyStateWanted = true
        } else {
            showEmptyState()
        }
    }

    /// Quitting began with the unsaved-changes review: save before anything closes.
    func willReviewForQuit() {
        guard !isRestoring else { return }
        restorer?.applicationWillQuit()
    }

    /// The review ended; `false` means the user cancelled the quit, so saving carries on.
    func reviewEnded(didReviewAll: Bool) {
        if !didReviewAll { restorer?.quitWasCancelled() }
    }

    /// The app is about to quit. Saved already if the quit went through the review.
    func willTerminate() {
        guard !isRestoring, let restorer, !restorer.isTerminating else { return }
        restorer.applicationWillQuit()
    }
}

/// Stands in for the delegate of `reviewUnsavedDocuments`, so the document controller learns how
/// the review ended (a cancelled quit) and then passes the answer on unchanged.
final class ReviewForwarder: NSObject {
    static let selector = #selector(ReviewForwarder.documentController(_:didReviewAll:contextInfo:))
    private let delegate: NSObject?
    private let originalSelector: Selector?
    private let onEnd: (Bool) -> Void

    init(delegate: Any?, selector: Selector?, onEnd: @escaping (Bool) -> Void) {
        self.delegate = delegate as? NSObject
        originalSelector = selector
        self.onEnd = onEnd
    }

    @objc func documentController(_ controller: NSDocumentController, didReviewAll: Bool, contextInfo: UnsafeMutableRawPointer?) {
        onEnd(didReviewAll)
        guard let delegate, let originalSelector, delegate.responds(to: originalSelector) else { return }
        typealias Callback = @convention(c) (AnyObject, Selector, NSDocumentController, Bool, UnsafeMutableRawPointer?) -> Void
        let implementation = unsafeBitCast(delegate.method(for: originalSelector), to: Callback.self)
        implementation(delegate, originalSelector, controller, didReviewAll, contextInfo)
    }
}

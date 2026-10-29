import AppKit
import Persistence

/// The app's document controller. It must be created before
/// `NSApplicationMain` (see main.swift): the first instance becomes `.shared`.
///
/// Opening a file that is already open brings its window or tab forward;
/// that is `NSDocumentController`'s own behaviour and is left alone (B3).
final class ReaderDocumentController: NSDocumentController {
    /// Called with the number of open documents after one opens or closes,
    /// one run-loop turn later so a close-then-open doesn't flash the empty state.
    var onDocumentsChange: ((Int) -> Void)?
    /// Tests turn this off so fixtures don't land in the user's recents.
    var recordsRecentDocuments = true
    /// Called when quitting starts, before any document is closed by the unsaved-changes review:
    /// the session is saved with every window still open.
    var onWillReviewForQuit: (() -> Void)?
    /// How that review ended: false if the user cancelled the quit.
    var onReviewEnded: ((Bool) -> Void)?
    /// The forwarder of the review in progress, kept until it answers.
    private var pendingReview: ReviewForwarder?

    override func reviewUnsavedDocuments(
        withAlertTitle title: String?, cancellable: Bool, delegate: Any?,
        didReviewAllSelector: Selector?, contextInfo: UnsafeMutableRawPointer?
    ) {
        onWillReviewForQuit?()
        let forwarder = ReviewForwarder(delegate: delegate, selector: didReviewAllSelector) { [weak self] didReviewAll in
            self?.onReviewEnded?(didReviewAll)
            self?.pendingReview = nil
        }
        pendingReview = forwarder
        super.reviewUnsavedDocuments(withAlertTitle: title, cancellable: cancellable, delegate: forwarder,
                                     didReviewAllSelector: ReviewForwarder.selector, contextInfo: contextInfo)
    }

    override func addDocument(_ document: NSDocument) {
        super.addDocument(document)
        documentsDidChange()
    }

    override func removeDocument(_ document: NSDocument) {
        super.removeDocument(document)
        documentsDidChange()
    }

    private func documentsDidChange() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            onDocumentsChange?(documents.count)
        }
    }

    override func noteNewRecentDocumentURL(_ url: URL) {
        guard recordsRecentDocuments else { return }
        super.noteNewRecentDocumentURL(url)
    }

    /// Clearing Open Recent also forgets what was stored for those files:
    /// positions, history, settings, paths and bookmarks.
    override func clearRecentDocuments(_ sender: Any?) {
        let cleared = recentDocumentURLs
        super.clearRecentDocuments(sender)
        Self.forgetStoredState(for: cleared, in: AppEnvironment.stateStore)
    }

    static func forgetStoredState(for urls: [URL], in store: DocumentStateStore?) {
        guard let store, !urls.isEmpty else { return }
        store.forget(fileURLs: urls)
        store.flush()
    }

    // A reader has no untitled documents: New (and the tab bar's +) opens one instead.
    override func newDocument(_ sender: Any?) {
        openDocument(sender)
    }

    override func makeUntitledDocument(ofType typeName: String) throws -> NSDocument {
        throw CocoaError(.featureUnsupported)
    }

    /// Opens each URL, or brings it forward if it is already open. Used for
    /// drops onto a window and for the empty state's recent files.
    static func openDocuments(at urls: [URL]) {
        let controller = NSDocumentController.shared
        for url in urls {
            controller.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { controller.presentError(error) }
            }
        }
    }
}

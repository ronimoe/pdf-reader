import AppKit

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

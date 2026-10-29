import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let emptyState = EmptyStateController()

    func applicationWillFinishLaunching(_ notification: Notification) {
        (NSDocumentController.shared as? ReaderDocumentController)?.onDocumentsChange = { [weak self] count in
            self?.emptyState.documentsDidChange(count: count)
        }
    }

    // A reader has no "new document". AppKit asks for an untitled file at
    // launch (when nothing was opened or restored) and on a Dock click with
    // no windows; both show the empty state instead.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        emptyState.show()
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}

import AppKit
import Persistence

/// App-wide services the windows use.
enum AppEnvironment {
    /// Per-document state (A2), in the app's container. Nil until launch
    /// finishes; tests inject their own store instead.
    static var stateStore: DocumentStateStore?
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let emptyState = EmptyStateController()

    func applicationWillFinishLaunching(_ notification: Notification) {
        AppEnvironment.stateStore = DocumentStateStore(directory: DocumentStateStore.defaultDirectory())
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

    /// Quitting doesn't close windows first, so remember every open
    /// document's position and write it all out now (Journey A step 5).
    func applicationWillTerminate(_ notification: Notification) {
        for document in NSDocumentController.shared.documents {
            (document as? ReaderDocument)?.readerWindowController?.saveAnchor()
        }
        AppEnvironment.stateStore?.flush()
    }
}

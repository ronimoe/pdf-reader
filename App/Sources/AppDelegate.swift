import AppKit
import Persistence

/// App-wide services the windows use.
enum AppEnvironment {
    /// Per-document state (A2), in the app's container. Nil until launch
    /// finishes; tests inject their own store instead.
    static var stateStore: DocumentStateStore?

    /// True when the app is hosting the unit tests.
    static var isHostingTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    /// Application Support in the container; a throwaway folder while
    /// hosting tests, so documents tests open never reach the user's state.
    static var stateDirectory: URL {
        isHostingTests
            ? FileManager.default.temporaryDirectory.appending(path: "LecternTestState-\(UUID().uuidString)", directoryHint: .isDirectory)
            : DocumentStateStore.defaultDirectory()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let emptyState = EmptyStateController()

    func applicationWillFinishLaunching(_ notification: Notification) {
        AppEnvironment.stateStore = DocumentStateStore(directory: AppEnvironment.stateDirectory)
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

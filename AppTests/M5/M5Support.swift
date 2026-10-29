import AppKit
import PDFKit
import Persistence
import ReaderCore
import ReaderKit
import Testing
@testable import Lectern

/// Parent suite for M5 (bookmarks, settings, session restore, updates, accessibility, shortcut
/// map, distraction-free mode). Serialized: several tests drive the shared document controller,
/// the main menu and the app's windows.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)), .noUI)
struct M5Tests {}

/// A reader window driven in-process: transparent, click-through, at the screen's origin, with
/// the frame and toolbar autosaves off so nothing reaches the user's own defaults.
@MainActor
final class M5Harness {
    let document: ReaderDocument
    let controller: ReaderWindowController
    let presenter = RecordingPresenter()
    let preferences: ReaderPreferences
    private let blockedUIBefore = UITripwire.shared.calls.count

    convenience init(_ data: Data, size: NSSize = NSSize(width: 800, height: 700), preferences: ReaderPreferences = .ephemeral()) throws {
        try self.init(document: ReaderDocument.loaded(data), store: nil, size: size, preferences: preferences)
    }

    convenience init(file: URL, store: DocumentStateStore?, size: NSSize = NSSize(width: 800, height: 700), preferences: ReaderPreferences = .ephemeral()) throws {
        try self.init(document: ReaderDocument.opened(file), store: store, size: size, preferences: preferences)
    }

    init(document: ReaderDocument, store: DocumentStateStore?, size: NSSize, preferences: ReaderPreferences) throws {
        self.document = document
        self.preferences = preferences
        controller = ReaderWindowController(
            document: document, passwordStore: InMemoryPasswordStore(), presenter: presenter, stateStore: store,
            previewPresenter: nil, urlOpener: RecordingURLOpener(), preferences: preferences, journal: nil
        )
        document.addWindowController(controller)
        let window = try #require(controller.window)
        M5Harness.makeInvisible(window, size: size)
        controller.splitViewController.view.layoutSubtreeIfNeeded()
        spin(timeout: 0.05) { false }
    }

    /// No frame or toolbar autosave, fully transparent, never takes the mouse.
    static func makeInvisible(_ window: NSWindow, size: NSSize? = nil) {
        window.setFrameAutosaveName("")
        window.toolbar?.autosavesConfiguration = false
        if let size { window.setContentSize(size) }
        window.setFrameOrigin(NSScreen.screens.first?.frame.origin ?? .zero)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
    }

    var window: NSWindow { controller.window! }
    var pane: ReaderPane { controller.pane }
    var view: ReaderPDFView { controller.pdfView }

    /// Puts the reader on `page`, as if they had scrolled there.
    @discardableResult
    func read(at page: Int, y: CGFloat = 520) -> ReadingAnchor {
        view.restore(ReadingAnchor(pageIndex: page, pointInPage: CGPoint(x: 0, y: y), scale: 1))
        return view.currentAnchor!
    }

    func close() {
        let blocked = UITripwire.shared.calls.dropFirst(blockedUIBefore)
        #expect(blocked.isEmpty, "a test tried to show UI: \(Array(blocked))")
        controller.window?.orderOut(nil)
        document.close()
    }
}

/// Every menu item, depth first.
@MainActor
func allMenuItems(_ menu: NSMenu) -> [NSMenuItem] {
    menu.items.flatMap { [$0] + ($0.submenu.map(allMenuItems) ?? []) }
}

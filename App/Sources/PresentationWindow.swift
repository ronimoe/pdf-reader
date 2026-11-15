import AppKit
import ReaderUI

/// Presents slides in a borderless window over a whole display (View ▸ Start Presentation).
///
/// It isn't a full-screen Space: the slides appear at once, without the Space animation, and
/// the reader window, its tabs and its own full screen are left as they are. While Lectern is
/// active the window sits above the menu bar and the Dock; while another app is, it's an
/// ordinary window, so switching to a demo shows the demo. The display doesn't sleep while it
/// shows.
final class ScreenPresentationPresenter: PresentationPresenting {
    private var window: PresentationWindow?
    private weak var controller: PresentationController?
    private var displayID: CGDirectDisplayID?
    private var activity: (any NSObjectProtocol)?
    private var observers: [any NSObjectProtocol] = []

    func present(_ controller: PresentationController, on screen: NSScreen?) {
        if let current = self.controller { dismiss(current) }
        guard let screen = screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let window = PresentationWindow(covering: screen.frame)
        window.title = controller.title ?? "Presentation"
        // Setting the content sizes the window to the view; the frame comes after.
        window.contentViewController = controller
        window.setFrame(screen.frame, display: false)
        window.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            dismiss(controller)
        }
        self.window = window
        self.controller = controller
        displayID = screen.displayID
        updateLevel()
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateLevel() }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateLevel() }
            },
            // A projector unplugged, or a resolution changed.
            center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refit() }
            },
        ]
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .userInitiated],
            reason: "Presenting slides"
        )
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        controller.didBegin()
    }

    func dismiss(_ controller: PresentationController) {
        guard controller === self.controller else { return }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        let window = self.window
        self.window = nil
        self.controller = nil
        displayID = nil
        window?.onClose = nil
        window?.orderOut(nil)
        window?.contentViewController = nil
        window?.close()
        controller.didEnd()
    }

    private func updateLevel() {
        window?.level = NSApp.isActive ? .statusBar : .normal
    }

    /// Back over the whole of its display, or of the main one if its display has gone.
    private func refit() {
        guard let window else { return }
        let screen = NSScreen.screens.first { $0.displayID == displayID } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        displayID = screen.displayID
        window.setFrame(screen.frame, display: true)
    }
}

/// The presentation's window: borderless, black, never a tab, never restored, not in the
/// Window menu. ⌘W ends the presentation rather than closing anything else.
final class PresentationWindow: NSWindow {
    var onClose: (() -> Void)?

    /// A window covering `frame`, a display's whole frame.
    convenience init(covering frame: NSRect) {
        self.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        backgroundColor = .black
        isOpaque = true
        hasShadow = false
        tabbingMode = .disallowed
        isRestorable = false
        isExcludedFromWindowsMenu = true
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        // Over a reader window that is in its own full-screen Space, on that Space.
        collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performClose(_ sender: Any?) {
        onClose?()
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // A borderless window has no close button, so AppKit would disable Close.
        if menuItem.action == #selector(performClose(_:)) { return true }
        return super.validateMenuItem(menuItem)
    }
}

extension NSScreen {
    /// The display's number, which stays the same while screens are added and removed.
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

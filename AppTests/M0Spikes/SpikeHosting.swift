import AppKit
import ObjectiveC
import PDFKit

// MARK: - Offscreen window

/// A borderless window can't become key by default, which would silently
/// change focus and field-editing behaviour. This one can.
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    /// The test host app is never active (activating it would steal focus
    /// from the person's foreground app), so the window is never really key.
    /// Reporting key makes AppKit treat clicks as in-window clicks instead of
    /// window-activating first clicks, like a user's click on a key window.
    var pretendsKey = true
    override var isKeyWindow: Bool { pretendsKey || super.isKeyWindow }
}

/// Hosts a view in a window placed far off every screen. Nothing is visible
/// and no privacy prompt is involved.
final class OffscreenHost {
    let window: KeyableWindow

    init(content: NSView, size: NSSize = NSSize(width: 700, height: 900)) {
        window = KeyableWindow(
            contentRect: NSRect(origin: CGPoint(x: -30_000, y: -30_000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.contentView = content
        window.orderFrontRegardless()
        window.makeKey()
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }
}

extension PDFView {
    /// Standard setup for spikes: fixed scale, single page, shows page 0.
    func spikeLoad(_ document: PDFDocument, mode: PDFDisplayMode = .singlePageContinuous) {
        autoScales = false
        displayMode = mode
        self.document = document
        scaleFactor = 1
        layoutDocumentView()
        if let first = document.page(at: 0) { go(to: first) }
        Spin.runLoop(0.15)
    }

    /// Window coordinates of a point given in page space.
    func windowPoint(_ pagePoint: CGPoint, on page: PDFPage) -> NSPoint {
        let inView = convert(pagePoint, from: page)
        return convert(inView, to: nil)
    }

    func windowPoint(centerOf annotation: PDFAnnotation) -> NSPoint {
        windowPoint(CGPoint(x: annotation.bounds.midX, y: annotation.bounds.midY), on: annotation.page!)
    }
}

// MARK: - Synthesised events

/// Builds NSEvents and sends them through `NSWindow.sendEvent`, so AppKit's
/// own hit-testing decides which view receives them, as with a real click.
enum Synth {
    private static var eventNumber = 1000

    static func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow, clickCount: Int = 1) -> NSEvent {
        eventNumber += 1
        return NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: eventNumber, clickCount: clickCount,
            pressure: type == .leftMouseUp ? 0 : 1
        )!
    }

    /// The view AppKit would deliver a click at `point` to.
    static func hitView(at point: NSPoint, in window: NSWindow) -> NSView? {
        guard let content = window.contentView else { return nil }
        return content.hitTest(content.superview?.convert(point, from: nil) ?? point)
    }

    /// A full click, dispatched the way an active window does: hit-test, then
    /// `mouseDown`/`mouseUp` on the hit view. (`NSWindow.sendEvent` can't be
    /// used: the test host app is never active, so AppKit treats every click
    /// as a window-activating first click and drops it.) The mouse-up is
    /// queued first, so a view that runs its own tracking loop finds it
    /// instead of hanging; if nobody consumed it, it is delivered afterwards.
    @discardableResult
    static func click(at point: NSPoint, in window: NSWindow) -> NSView? {
        guard let target = hitView(at: point, in: window) else { return nil }
        let down = mouse(.leftMouseDown, at: point, in: window)
        let up = mouse(.leftMouseUp, at: point, in: window)
        NSApp.postEvent(up, atStart: true)
        target.mouseDown(with: down)
        if let pending = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) {
            target.mouseUp(with: pending)
        }
        Spin.runLoop(0.1)
        return target
    }

    static func moved(to point: NSPoint, in window: NSWindow) {
        window.sendEvent(mouse(.mouseMoved, at: point, in: window, clickCount: 0))
    }

    static func key(_ characters: String, keyCode: UInt16, in window: NSWindow, modifiers: NSEvent.ModifierFlags = []) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode
            )!
            window.sendEvent(event)
        }
        Spin.runLoop(0.05)
    }

    static let tabKeyCode: UInt16 = 48
    static let returnKeyCode: UInt16 = 36
    static let spaceKeyCode: UInt16 = 49
}

// MARK: - NSWorkspace tripwire

/// Replaces NSWorkspace's open and launch methods in the test process with
/// recorders, so nothing a test does can open a URL, file or app. It is a
/// detector, not a guarantee: code that calls LaunchServices directly would
/// bypass it, which is why every fixture target is also inert (unregistered
/// schemes, `.invalid` hosts, paths that don't exist).
nonisolated final class WorkspaceTripwire: @unchecked Sendable {
    static let shared = WorkspaceTripwire()

    private let state = Locked<(installed: Bool, calls: [String])>((false, []))

    var calls: [String] { state.current.calls }
    func reset() { state.withLock { $0.calls.removeAll() } }
    func record(_ call: String) { state.withLock { $0.calls.append(call) } }

    func install() {
        let shouldInstall = state.withLock { s -> Bool in
            if s.installed { return false }
            s.installed = true
            return true
        }
        guard shouldInstall else { return }

        typealias URLBool = @convention(block) (NSWorkspace, NSURL) -> Bool
        typealias URLConfig = @convention(block) (NSWorkspace, NSURL, AnyObject, AnyObject?) -> Void
        typealias URLsAppConfig = @convention(block) (NSWorkspace, NSArray, NSURL, AnyObject, AnyObject?) -> Void
        typealias PathBool = @convention(block) (NSWorkspace, NSString) -> Bool
        typealias PathAppBool = @convention(block) (NSWorkspace, NSString, NSString?) -> Bool
        typealias PathAppDeactBool = @convention(block) (NSWorkspace, NSString, NSString?, Bool) -> Bool
        typealias URLOptsConfigErr = @convention(block) (NSWorkspace, NSURL, UInt, NSDictionary, AnyObject?) -> AnyObject?
        typealias URLsBundle = @convention(block) (NSWorkspace, NSArray, NSString?, UInt, AnyObject?, AnyObject?) -> Bool
        typealias Select = @convention(block) (NSWorkspace, NSArray) -> Void

        let tripwire = self
        let replacements: [(String, Any)] = [
            ("openURL:", { (_, url) in tripwire.record("openURL: \(url)"); return true } as URLBool),
            ("openURL:configuration:completionHandler:", { (_, url, _, _) in tripwire.record("openURL:configuration: \(url)") } as URLConfig),
            ("openApplicationAtURL:configuration:completionHandler:", { (_, url, _, _) in tripwire.record("openApplicationAtURL: \(url)") } as URLConfig),
            ("openURLs:withApplicationAtURL:configuration:completionHandler:", { (_, urls, app, _, _) in tripwire.record("openURLs: \(urls) app: \(app)") } as URLsAppConfig),
            ("openFile:", { (_, path) in tripwire.record("openFile: \(path)"); return true } as PathBool),
            ("launchApplication:", { (_, path) in tripwire.record("launchApplication: \(path)"); return true } as PathBool),
            ("openFile:withApplication:", { (_, path, app) in tripwire.record("openFile: \(path) app: \(String(describing: app))"); return true } as PathAppBool),
            ("openFile:withApplication:andDeactivate:", { (_, path, app, _) in tripwire.record("openFile: \(path) app: \(String(describing: app))"); return true } as PathAppDeactBool),
            ("openURL:options:configuration:error:", { (_, url, _, _, _) in tripwire.record("openURL:options: \(url)"); return nil } as URLOptsConfigErr),
            ("openURLs:withAppBundleIdentifier:options:additionalEventParamDescriptor:launchIdentifiers:", { (_, urls, _, _, _, _) in tripwire.record("openURLs:bundle: \(urls)"); return true } as URLsBundle),
            ("activateFileViewerSelectingURLs:", { (_, urls) in tripwire.record("activateFileViewer: \(urls)") } as Select),
        ]
        for (name, block) in replacements {
            guard let method = class_getInstanceMethod(NSWorkspace.self, NSSelectorFromString(name)) else {
                SpikeLog.note("tripwire", "selector not found: \(name)")
                continue
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }
    }
}

// MARK: - Runtime introspection

nonisolated enum Runtime {
    /// Whether `cls` provides its own implementation of `selector`, rather
    /// than inheriting the one from `base`.
    static func overrides(_ cls: AnyClass, _ selector: Selector, from base: AnyClass) -> Bool {
        guard let mine = class_getInstanceMethod(cls, selector) else { return false }
        guard let theirs = class_getInstanceMethod(base, selector) else { return true }
        return method_getImplementation(mine) != method_getImplementation(theirs)
    }
}

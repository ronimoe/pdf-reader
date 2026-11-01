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

/// Hosts a view in a window nobody can see or click: fully transparent
/// (`alphaValue = 0`) and click-through (`ignoresMouseEvents`). No privacy
/// prompt is involved.
///
/// It sits on a real screen rather than far off-screen: events that pass
/// through the app's event queue are converted to screen coordinates and
/// back, and for a window outside every display that round trip corrupts
/// `locationInWindow` (observed: a queued mouse-up at (237, 791) came back
/// as (-3153, -2508)). PDFKit's link tracking peeks the queued mouse-up, so
/// this matters.
final class OffscreenHost {
    let window: KeyableWindow

    init(content: NSView, size: NSSize = NSSize(width: 700, height: 900)) {
        // At the primary screen's origin, so window and screen coordinates
        // coincide (see `Synth.cgMouse`).
        let origin = NSScreen.screens.first?.frame.origin ?? .zero
        window = KeyableWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.animationBehavior = .none
        window.hasShadow = false
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

    /// A mouse event built from a CGEvent with an explicit global location.
    /// `NSEvent.mouseEvent(with:location:…)` events that pass through the
    /// app's queue come back carrying the live cursor position instead of
    /// their own; CGEvent-backed ones keep theirs. Only ever handed to
    /// `NSApp.postEvent` or a view, never posted to a system event tap.
    static func cgMouse(_ type: CGEventType, at point: NSPoint, in window: NSWindow) -> NSEvent {
        let screenPoint = window.convertPoint(toScreen: point)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let global = CGPoint(x: screenPoint.x, y: primaryHeight - screenPoint.y)
        let cgEvent = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: global, mouseButton: .left)!
        cgEvent.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        cgEvent.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
        cgEvent.setIntegerValueField(.mouseEventClickState, value: 1)
        return NSEvent(cgEvent: cgEvent)!
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
    ///
    /// The queued copy is CGEvent-backed so it keeps its location (PDFKit's
    /// link tracking reads it; see `cgMouse`); `mouseUp` itself gets the
    /// original NSEvent.
    @discardableResult
    static func click(at point: NSPoint, in window: NSWindow) -> NSView? {
        guard let target = hitView(at: point, in: window) else { return nil }
        let down = mouse(.leftMouseDown, at: point, in: window)
        let up = mouse(.leftMouseUp, at: point, in: window)
        NSApp.postEvent(cgMouse(.leftMouseUp, at: point, in: window), atStart: true)
        target.mouseDown(with: down)
        if NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) != nil {
            target.mouseUp(with: up)
        }
        Spin.runLoop(0.1)
        return target
    }

    /// A click through `NSWindow.sendEvent`, as AppKit dispatches a person's, so gesture
    /// recognizers see it too (macOS 27's PDFView acts only on these). AppKit drops it unless the
    /// app is active, so it is only for where the test host already is (CI); nothing here ever
    /// activates it. The mouse-up is queued first, as in `click`.
    static func windowClick(at point: NSPoint, in window: NSWindow) {
        NSApp.postEvent(cgMouse(.leftMouseUp, at: point, in: window), atStart: true)
        window.sendEvent(mouse(.leftMouseDown, at: point, in: window))
        if NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) != nil {
            window.sendEvent(mouse(.leftMouseUp, at: point, in: window))
        }
        Spin.runLoop(0.3)
    }

    /// Key presses through `NSWindow.sendEvent`, for the same cases as `windowClick`.
    static func windowKey(_ characters: String, keyCode: UInt16, in window: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode
            )!
            window.sendEvent(event)
        }
        Spin.runLoop(0.05)
    }

    static func moved(to point: NSPoint, in window: NSWindow) {
        window.sendEvent(mouse(.mouseMoved, at: point, in: window, clickCount: 0))
    }

    /// A key press delivered to the window's first responder, as an active
    /// key window would.
    static func key(_ characters: String, keyCode: UInt16, in window: NSWindow, modifiers: NSEvent.ModifierFlags = []) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode
            )!
            let responder = window.firstResponder ?? window
            if type == .keyDown { responder.keyDown(with: event) } else { responder.keyUp(with: event) }
        }
        Spin.runLoop(0.05)
    }

    static func type(_ text: String, in window: NSWindow) {
        for character in text { key(String(character), keyCode: 0, in: window) }
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

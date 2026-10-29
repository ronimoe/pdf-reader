import AppKit
import ObjectiveC
import Testing

/// No test may put UI on screen: alerts, save panels, error presentation and modal sessions are
/// replaced, for the whole test process, with recorders that show nothing. A test (or a harness's
/// `close()`) checks `calls` to fail on any attempt. Installed when the test bundle loads, by
/// `LecternTestPrincipal`, before any test runs.
nonisolated final class UITripwire: @unchecked Sendable {
    static let shared = UITripwire()

    private let state = Locked<(installed: Bool, calls: [String], expected: [String], expecting: Int)>((false, [], [], 0))

    /// Attempts to show UI that no test asked for: each one fails a test.
    var calls: [String] { state.current.calls }
    /// Attempts a test made on purpose, inside `expecting`.
    var expected: [String] { state.current.expected }
    var isInstalled: Bool { state.current.installed }
    func record(_ call: String) {
        let wasExpected = state.withLock { s -> Bool in
            if s.expecting > 0 { s.expected.append(call) } else { s.calls.append(call) }
            return s.expecting > 0
        }
        print("UITripwire: blocked \(call)\(wasExpected ? " (expected)" : "")")
    }

    /// Runs `body`, which tries to show UI on purpose; what it tries is recorded in `expected`
    /// and returned, not counted against any test.
    @discardableResult
    func expecting(_ body: () throws -> Void) rethrows -> [String] {
        let start = state.withLock { s -> Int in
            s.expecting += 1
            return s.expected.count
        }
        defer { state.withLock { $0.expecting -= 1 } }
        try body()
        return Array(state.current.expected.dropFirst(start))
    }

    func install() {
        let shouldInstall = state.withLock { s -> Bool in
            if s.installed { return false }
            s.installed = true
            return true
        }
        guard shouldInstall else { return }
        let tripwire = self

        typealias RunModal = @convention(block) (AnyObject) -> Int
        typealias Response = @convention(block) (Int) -> Void
        typealias SheetModal = @convention(block) (AnyObject, NSWindow?, Response?) -> Void
        typealias Begin = @convention(block) (AnyObject, Response?) -> Void
        typealias PresentError = @convention(block) (NSApplication, NSError) -> Bool
        typealias PresentErrorModal = @convention(block) (NSApplication, NSError, NSWindow?, AnyObject?, Selector?, UnsafeMutableRawPointer?) -> Void
        typealias RunModalForWindow = @convention(block) (NSApplication, NSWindow) -> Int

        func replace(_ cls: AnyClass, _ name: String, _ block: Any) {
            guard let method = class_getInstanceMethod(cls, NSSelectorFromString(name)) else {
                print("UITripwire: selector not found: \(cls).\(name)")
                return
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }

        let cancel = NSApplication.ModalResponse.cancel.rawValue
        replace(NSAlert.self, "runModal", { (alert: AnyObject) in
            tripwire.record("NSAlert.runModal: \((alert as? NSAlert)?.messageText ?? "?")")
            return cancel
        } as RunModal)
        // Each blocked sheet still ends: its handler gets Cancel, so no flow waits forever.
        func finish(_ handler: Response?) {
            guard let handler else { return }
            // AppKit calls these on the main thread and expects the answer there, later.
            nonisolated(unsafe) let unsafeHandler = handler
            DispatchQueue.main.async { unsafeHandler(cancel) }
        }
        replace(NSAlert.self, "beginSheetModalForWindow:completionHandler:", { (alert: AnyObject, _, handler) in
            tripwire.record("NSAlert.beginSheetModal: \((alert as? NSAlert)?.messageText ?? "?")")
            finish(handler)
        } as SheetModal)
        replace(NSSavePanel.self, "runModal", { (_: AnyObject) in
            tripwire.record("NSSavePanel.runModal")
            return cancel
        } as RunModal)
        replace(NSSavePanel.self, "beginSheetModalForWindow:completionHandler:", { (_: AnyObject, _, handler) in
            tripwire.record("NSSavePanel.beginSheetModal")
            finish(handler)
        } as SheetModal)
        replace(NSSavePanel.self, "beginWithCompletionHandler:", { (_: AnyObject, handler) in
            tripwire.record("NSSavePanel.begin")
            finish(handler)
        } as Begin)
        replace(NSApplication.self, "presentError:", { (_, error) in
            tripwire.record("NSApplication.presentError: \(error.localizedDescription)")
            return false
        } as PresentError)
        replace(NSApplication.self, "presentError:modalForWindow:delegate:didPresentSelector:contextInfo:", { (_, error, _, _, _, _) in
            tripwire.record("NSApplication.presentError:modalForWindow: \(error.localizedDescription)")
        } as PresentErrorModal)
        replace(NSApplication.self, "runModalForWindow:", { (_, window) in
            tripwire.record("NSApplication.runModalForWindow: \(window.title)")
            return cancel
        } as RunModalForWindow)
    }
}

/// The test bundle's principal class: XCTest creates it when the bundle loads, before any test.
@objc(LecternTestPrincipal)
nonisolated final class LecternTestPrincipal: NSObject {
    override init() {
        super.init()
        UITripwire.shared.install()
    }
}

/// Fails any test during which UI was attempted that the test didn't expect. Applied to every
/// top-level suite, and recursive, so it covers every test in the bundle. With suites running in
/// parallel an attempt may be reported against a test running at the same moment; either way a
/// test fails.
struct NoUITrait: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        guard testCase != nil else {
            try await function()
            return
        }
        let before = UITripwire.shared.calls.count
        try await function()
        let attempted = UITripwire.shared.calls.dropFirst(before)
        if !attempted.isEmpty {
            Issue.record("A test tried to show UI: \(Array(attempted))")
        }
    }
}

extension Trait where Self == NoUITrait {
    /// No UI may appear: see `UITripwire`.
    static var noUI: Self { Self() }
}

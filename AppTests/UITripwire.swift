import AppKit
import ObjectiveC

/// No test may put UI on screen: alerts, save panels, error presentation and modal sessions are
/// replaced, for the whole test process, with recorders that show nothing. A test (or a harness's
/// `close()`) checks `calls` to fail on any attempt. Installed when the test bundle loads, by
/// `LecternTestPrincipal`, before any test runs.
nonisolated final class UITripwire: @unchecked Sendable {
    static let shared = UITripwire()

    private let state = Locked<(installed: Bool, calls: [String])>((false, []))

    var calls: [String] { state.current.calls }
    var isInstalled: Bool { state.current.installed }
    func reset() { state.withLock { $0.calls.removeAll() } }
    func record(_ call: String) {
        state.withLock { $0.calls.append(call) }
        print("UITripwire: blocked \(call)")
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
        typealias SheetModal = @convention(block) (AnyObject, NSWindow?, AnyObject?) -> Void
        typealias Begin = @convention(block) (AnyObject, AnyObject?) -> Void
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
        replace(NSAlert.self, "beginSheetModalForWindow:completionHandler:", { (alert: AnyObject, _, _) in
            tripwire.record("NSAlert.beginSheetModal: \((alert as? NSAlert)?.messageText ?? "?")")
        } as SheetModal)
        replace(NSSavePanel.self, "runModal", { (_: AnyObject) in
            tripwire.record("NSSavePanel.runModal")
            return cancel
        } as RunModal)
        replace(NSSavePanel.self, "beginSheetModalForWindow:completionHandler:", { (_: AnyObject, _, _) in
            tripwire.record("NSSavePanel.beginSheetModal")
        } as SheetModal)
        replace(NSSavePanel.self, "beginWithCompletionHandler:", { (_: AnyObject, _) in
            tripwire.record("NSSavePanel.begin")
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

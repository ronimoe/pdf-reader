import AppKit
import ReaderUI
import SwiftUI

/// Shows a reader window's sheets: the password prompt, Go to Page and the
/// explanation of a blocked action. Tests swap in a recorder so no modal UI
/// appears.
protocol ReaderPresenting: AnyObject {
    func showPasswordPrompt(_ model: PasswordPromptModel, on window: NSWindow)
    func dismissPasswordPrompt(on window: NSWindow)
    func showGoToPage(_ model: GoToPageModel, on window: NSWindow)
    func dismissGoToPage(on window: NSWindow)
    /// `enterOwnerPassword` is called if the user chooses to enter it.
    func explain(_ action: BlockedAction, on window: NSWindow, enterOwnerPassword: @escaping () -> Void)
}

final class SheetPresenter: ReaderPresenting {
    private var passwordSheet: NSWindow?
    private var goToPageSheet: NSWindow?

    func showGoToPage(_ model: GoToPageModel, on window: NSWindow) {
        dismissGoToPage(on: window)
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: GoToPageView(model: model)))
        sheet.setAccessibilityLabel("Go to Page")
        goToPageSheet = sheet
        window.beginSheet(sheet)
    }

    func dismissGoToPage(on window: NSWindow) {
        guard let sheet = goToPageSheet else { return }
        goToPageSheet = nil
        window.endSheet(sheet)
    }

    func showPasswordPrompt(_ model: PasswordPromptModel, on window: NSWindow) {
        dismissPasswordPrompt(on: window)
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: PasswordPromptView(model: model)))
        sheet.setAccessibilityLabel(model.title)
        passwordSheet = sheet
        window.beginSheet(sheet)
    }

    func dismissPasswordPrompt(on window: NSWindow) {
        guard let sheet = passwordSheet else { return }
        passwordSheet = nil
        window.endSheet(sheet)
    }

    func explain(_ action: BlockedAction, on window: NSWindow, enterOwnerPassword: @escaping () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = action.title
        alert.informativeText = action.message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Enter Owner Password…")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertSecondButtonReturn else { return }
            // Let the alert's sheet finish closing before the next one opens.
            DispatchQueue.main.async { enterOwnerPassword() }
        }
    }
}

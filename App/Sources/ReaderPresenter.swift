import AppKit
import ReaderKit
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
    /// A link with a scheme other than http or https (A4): shows the URL and
    /// calls `open` only if the user confirms.
    func confirmOpening(_ url: URL, on window: NSWindow, open: @escaping () -> Void)
    /// A GoToR, Launch, SubmitForm or JavaScript link: says it was blocked.
    func explainBlockedLink(_ link: BlockedLink, on window: NSWindow)
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

    func confirmOpening(_ url: URL, on window: NSWindow, open: @escaping () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Open this link in another app?"
        alert.informativeText = "The link goes to:\n\(url.absoluteString)\n\nIt isn’t a web page. Open it only if you trust the document."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Open Link")
        alert.beginSheetModal(for: window) { response in
            if response == .alertSecondButtonReturn { open() }
        }
    }

    func explainBlockedLink(_ link: BlockedLink, on window: NSWindow) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = link.title
        alert.informativeText = link.message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }
}

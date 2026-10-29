import AppKit
import ReaderKit
import ReaderUI
import SwiftUI
import UniformTypeIdentifiers

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

    // MARK: Annotations and saving (M4)

    /// Why an annotation action did nothing. `enterOwnerPassword` is non-nil when the owner
    /// password would lift the restriction (B6).
    func explainAnnotationRefusal(_ refusal: AnnotationRefusal, on window: NSWindow, enterOwnerPassword: (() -> Void)?)
    /// The file changed on disk while annotations are unsaved (B7).
    func askAboutChangedFile(name: String, on window: NSWindow, choice: @escaping (ChangedFileChoice) -> Void)
    /// B7 Reload: confirms that the unsaved annotations will be lost.
    func confirmDiscardingAnnotations(name: String, on window: NSWindow, confirmed: @escaping (Bool) -> Void)
    /// Where B7's copy goes; nil if cancelled.
    func chooseCopyDestination(suggestedName: String, on window: NSWindow, chosen: @escaping (URL?) -> Void)
    /// Unsaved annotations from a session that ended unexpectedly, for these exact bytes (A1).
    func offerJournalRestore(name: String, changeCount: Int, on window: NSWindow, choice: @escaping (JournalChoice) -> Void)
    /// Unsaved annotations for another version of the file, or a journal that can't be read.
    /// Discard deletes it; Keep leaves it for later. It is never deleted silently.
    func explainStaleJournal(name: String, unreadable: Bool, on window: NSWindow, choice: @escaping (JournalChoice) -> Void)
    /// An error the document reports, such as a failed save. `completion` runs once it is
    /// dismissed.
    func presentError(_ error: any Error, on window: NSWindow, completion: @escaping () -> Void)
    /// The small popover for a note's text or a markup comment. `finished` gets the text to keep,
    /// or nil if cancelled.
    func editAnnotationText(heading: String, text: String, relativeTo rect: NSRect, of view: NSView, finished: @escaping (String?) -> Void)

    // MARK: Bookmarks (M5)

    /// Asks for a bookmark's new name; `finished` gets it, or nil if cancelled.
    func renameBookmark(currentName: String, on window: NSWindow, finished: @escaping (String?) -> Void)
    /// Where the bookmarks' JSON goes; nil if cancelled.
    func chooseBookmarkExportDestination(suggestedName: String, on window: NSWindow, chosen: @escaping (URL?) -> Void)
}

enum ChangedFileChoice: Equatable {
    case reload, saveCopy
}

enum JournalChoice: Equatable {
    case restore, discard, keep
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

    // MARK: Annotations and saving

    /// Sheets queue: AppKit shows one at a time per window.
    private func present(_ alert: NSAlert, on window: NSWindow, _ handler: @escaping (NSApplication.ModalResponse) -> Void) {
        if window.attachedSheet != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak window] in
                guard let self, let window else { return }
                self.present(alert, on: window, handler)
            }
            return
        }
        alert.beginSheetModal(for: window, completionHandler: handler)
    }

    func explainAnnotationRefusal(_ refusal: AnnotationRefusal, on window: NSWindow, enterOwnerPassword: (() -> Void)?) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = refusal.title
        alert.informativeText = refusal.message
        alert.addButton(withTitle: "OK")
        if enterOwnerPassword != nil { alert.addButton(withTitle: "Enter Owner Password…") }
        present(alert, on: window) { response in
            guard response == .alertSecondButtonReturn, let enterOwnerPassword else { return }
            DispatchQueue.main.async { enterOwnerPassword() }
        }
    }

    func askAboutChangedFile(name: String, on window: NSWindow, choice: @escaping (ChangedFileChoice) -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(name)” changed on disk"
        alert.informativeText = "Another app changed the file while you have unsaved annotations. Reload shows the new version and discards your unsaved annotations. Save a Copy keeps them in a new file, made from the version you have open."
        alert.addButton(withTitle: "Save a Copy…")
        alert.addButton(withTitle: "Reload")
        present(alert, on: window) { response in
            let picked: ChangedFileChoice = response == .alertSecondButtonReturn ? .reload : .saveCopy
            DispatchQueue.main.async { choice(picked) }
        }
    }

    func confirmDiscardingAnnotations(name: String, on window: NSWindow, confirmed: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Discard your unsaved annotations?"
        alert.informativeText = "Reloading “\(name)” shows the version on disk. The annotations you haven’t saved will be lost, and this can’t be undone."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Reload and Discard")
        alert.buttons[1].hasDestructiveAction = true
        present(alert, on: window) { response in
            DispatchQueue.main.async { confirmed(response == .alertSecondButtonReturn) }
        }
    }

    func chooseCopyDestination(suggestedName: String, on window: NSWindow, chosen: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = suggestedName
        panel.message = "Save a copy of the version you have open, with your unsaved annotations."
        panel.beginSheetModal(for: window) { response in
            let url = response == .OK ? panel.url : nil
            DispatchQueue.main.async { chosen(url) }
        }
    }

    func offerJournalRestore(name: String, changeCount: Int, on window: NSWindow, choice: @escaping (JournalChoice) -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Restore unsaved annotations?"
        alert.informativeText = "Lectern closed unexpectedly while “\(name)” had unsaved annotations (\(changeCount) \(changeCount == 1 ? "change" : "changes")). You can restore them and save, or discard them."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Discard")
        present(alert, on: window) { response in
            DispatchQueue.main.async { choice(response == .alertSecondButtonReturn ? .discard : .restore) }
        }
    }

    func explainStaleJournal(name: String, unreadable: Bool, on window: NSWindow, choice: @escaping (JournalChoice) -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Unsaved annotations can’t be restored"
        alert.informativeText = unreadable
            ? "Lectern kept unsaved annotations for “\(name)”, but the record can’t be read."
            : "Lectern kept unsaved annotations for “\(name)”, but the file has changed since, so they no longer fit it. They can’t be applied safely."
        alert.addButton(withTitle: "Keep for Now")
        alert.addButton(withTitle: "Discard")
        present(alert, on: window) { response in
            DispatchQueue.main.async { choice(response == .alertSecondButtonReturn ? .discard : .keep) }
        }
    }

    func presentError(_ error: any Error, on window: NSWindow, completion: @escaping () -> Void) {
        present(NSAlert(error: error), on: window) { _ in completion() }
    }

    func editAnnotationText(heading: String, text: String, relativeTo rect: NSRect, of view: NSView, finished: @escaping (String?) -> Void) {
        let editor = AnnotationTextEditorController(heading: heading, text: text)
        let popover = Self.makeEditorPopover()
        popover.contentViewController = editor
        editor.presentingPopover = popover
        editor.onFinish = finished
        let delegate = PopoverCloseObserver { [weak editor] in editor?.popoverDidClose() }
        popover.delegate = delegate
        objc_setAssociatedObject(popover, &PopoverCloseObserver.key, delegate, .OBJC_ASSOCIATION_RETAIN)
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }
}

// MARK: Bookmarks

extension SheetPresenter {
    /// The annotation text popover: transient, and still while Reduce Motion is on.
    static func makeEditorPopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = !Motion.isReduced
        return popover
    }

    func renameBookmark(currentName: String, on window: NSWindow, finished: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Rename Bookmark"
        let field = NSTextField(string: currentName)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        field.setAccessibilityLabel("Bookmark name")
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            let name = response == .alertFirstButtonReturn ? field.stringValue : nil
            DispatchQueue.main.async { finished(name) }
        }
    }

    func chooseBookmarkExportDestination(suggestedName: String, on window: NSWindow, chosen: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = suggestedName
        panel.message = "Export this document’s bookmarks as JSON."
        panel.beginSheetModal(for: window) { response in
            let url = response == .OK ? panel.url : nil
            DispatchQueue.main.async { chosen(url) }
        }
    }
}

/// Keeps the text typed into an annotation popover that closes by a click elsewhere.
private final class PopoverCloseObserver: NSObject, NSPopoverDelegate {
    nonisolated(unsafe) static var key = 0
    let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func popoverDidClose(_ notification: Notification) { onClose() }
}

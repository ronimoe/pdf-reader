import AppKit
import Persistence
import ReaderCore
import ReaderKit
import ReaderUI

/// One reader window (or tab) for one document. Owns the document's view
/// settings, the toolbar, the reading commands, and the unlock flow (B6).
final class ReaderWindowController: NSWindowController {
    let pdfView = ReaderPDFView(frame: .zero)
    /// The layout, zoom and rotation of this document (B1, B9). Stored
    /// per document from M2.
    private(set) var settings = ViewSettings()
    /// The password sheet's model while it is showing.
    private(set) var passwordPrompt: PasswordPromptModel?

    private weak var readerDocument: ReaderDocument?
    private let passwordStore: any DocumentPasswordStore
    private let presenter: any ReaderPresenting
    private var didCheckPasswords = false

    init(
        document: ReaderDocument,
        passwordStore: any DocumentPasswordStore = KeychainPasswordStore(),
        presenter: any ReaderPresenting = SheetPresenter()
    ) {
        readerDocument = document
        self.passwordStore = passwordStore
        self.presenter = presenter
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 1000),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "ReaderWindow"
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.titleVisibility = .visible
        window.toolbarStyle = .unifiedCompact
        window.setFrameAutosaveName("ReaderWindow")
        super.init(window: window)

        window.contentView = pdfView
        window.toolbar = makeToolbar()
        pdfView.onUserZoom = { [weak self] scale in self?.settings.zoom = .scale(scale) }
        pdfView.onCopyBlocked = { [weak self] in self?.explainBlocked(.copy) }
        pdfView.onOpenFiles = { urls in ReaderDocumentController.openDocuments(at: urls) }
        pdfView.contextMenuItems = {
            ReaderCommands.zoomItems() + [.separator()] + ReaderCommands.readingOptionItems()
        }
        window.delegate = self
        showContentIfReadable()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        checkPasswordsIfNeeded()
    }

    // Restored windows can come back without showWindow; checking when the
    // window first becomes key covers them.
    func windowDidBecomeKey(_ notification: Notification) {
        checkPasswordsIfNeeded()
    }

    /// True once the pages are on screen (the document is unlocked).
    var isShowingContent: Bool { pdfView.document != nil }

    private func showContentIfReadable() {
        guard !isShowingContent, let readerDocument, !readerDocument.isPasswordLocked,
              let pdf = readerDocument.pdfDocument
        else { return }
        readerDocument.applyViewRotation(settings.rotation)
        pdfView.document = pdf
        pdfView.apply(settings, hints: readerDocument.layoutHints)
        window?.makeFirstResponder(pdfView)
    }

    // MARK: Passwords (B6)

    /// Tries a password remembered in the Keychain, then asks for one if the
    /// document is still locked. A remembered owner password also lifts the
    /// restrictions of a document that opened without one.
    func checkPasswordsIfNeeded() {
        guard let readerDocument, !didCheckPasswords else { return }
        didCheckPasswords = true
        if readerDocument.isPasswordLocked || !readerDocument.hasOwnerAccess,
           let stored = try? passwordStore.password(for: readerDocument.documentKey) {
            if readerDocument.unlock(withPassword: stored) {
                showContentIfReadable()
            } else {
                // The key includes this file's encryption entries, so the
                // entry is this file's own and its password no longer works.
                try? passwordStore.removePassword(for: readerDocument.documentKey)
            }
        }
        if readerDocument.isPasswordLocked {
            promptForPassword(.open)
        }
    }

    func promptForPassword(_ purpose: PasswordPromptModel.Purpose) {
        guard let window, let readerDocument else { return }
        let model = PasswordPromptModel(documentName: readerDocument.displayName, purpose: purpose)
        model.onSubmit = { [weak self] password, remember in
            self?.submitPassword(password, remember: remember, purpose: purpose) ?? false
        }
        model.onCancel = { [weak self] in self?.cancelPasswordPrompt(purpose) }
        passwordPrompt = model
        presenter.showPasswordPrompt(model, on: window)
    }

    /// Returns false for a wrong password, leaving the prompt up. On an open
    /// document only the owner password counts (see `ReaderDocument.unlock`).
    func submitPassword(_ password: String, remember: Bool, purpose: PasswordPromptModel.Purpose) -> Bool {
        guard let readerDocument, readerDocument.unlock(withPassword: password) else { return false }
        if remember {
            // Failing to remember never blocks reading; the user is asked next time.
            try? passwordStore.setPassword(password, for: readerDocument.documentKey)
        }
        dismissPasswordPrompt()
        showContentIfReadable()
        return true
    }

    /// Cancelling the open prompt closes the document; cancelling the owner
    /// prompt only dismisses it.
    func cancelPasswordPrompt(_ purpose: PasswordPromptModel.Purpose) {
        dismissPasswordPrompt()
        if purpose == .open {
            readerDocument?.close()
        }
    }

    private func dismissPasswordPrompt() {
        passwordPrompt = nil
        if let window { presenter.dismissPasswordPrompt(on: window) }
    }

    /// Tells the user why an action did nothing, and offers the owner password.
    func explainBlocked(_ action: BlockedAction) {
        guard let window else { return }
        presenter.explain(action, on: window) { [weak self] in
            self?.promptForPassword(.removeRestrictions)
        }
    }

    // MARK: Reading commands

    @objc func increaseZoom(_ sender: Any?) {
        settings.zoomIn(from: pdfView.scaleFactor)
        pdfView.setZoomMode(settings.zoom)
    }

    @objc func decreaseZoom(_ sender: Any?) {
        settings.zoomOut(from: pdfView.scaleFactor)
        pdfView.setZoomMode(settings.zoom)
    }

    @objc func zoomToActualSize(_ sender: Any?) { setZoom(.actualSize) }
    @objc func zoomToFitPage(_ sender: Any?) { setZoom(.fitPage) }
    @objc func zoomToFitWidth(_ sender: Any?) { setZoom(.fitWidth) }

    @objc func showSinglePage(_ sender: Any?) { updateLayout { $0.pages = .single } }
    @objc func showTwoPages(_ sender: Any?) { updateLayout { $0.pages = .twoUp } }
    @objc func scrollContinuously(_ sender: Any?) { updateLayout { $0.scrolling = .continuous } }
    @objc func scrollPageByPage(_ sender: Any?) { updateLayout { $0.scrolling = .paged } }

    @objc func toggleCoverPage(_ sender: Any?) {
        let hints = layoutHints
        updateLayout { $0.toggleCoverPageAlone(hints: hints) }
    }

    @objc func toggleRightToLeft(_ sender: Any?) {
        let hints = layoutHints
        updateLayout { $0.toggleRightToLeft(hints: hints) }
    }

    @objc func rotateDocumentLeft(_ sender: Any?) { updateLayout { $0.rotateLeft() } }
    @objc func rotateDocumentRight(_ sender: Any?) { updateLayout { $0.rotateRight() } }

    private var layoutHints: DocumentLayoutHints { readerDocument?.layoutHints ?? .none }

    private func setZoom(_ mode: ZoomMode) {
        settings.zoom = mode
        pdfView.setZoomMode(mode)
    }

    private func updateLayout(_ change: (inout ViewSettings) -> Void) {
        let rotation = settings.rotation
        change(&settings)
        if settings.rotation != rotation {
            readerDocument?.applyViewRotation(settings.rotation)
            pdfView.layoutDocumentView()
        }
        pdfView.apply(settings, hints: layoutHints)
    }

    // MARK: Validation

    private func isEnabled(_ action: Selector?) -> Bool {
        guard isShowingContent else { return false }
        switch action {
        case #selector(increaseZoom(_:)): return pdfView.scaleFactor < ZoomMode.maximumScale * 0.99
        case #selector(decreaseZoom(_:)): return pdfView.scaleFactor > ZoomMode.minimumScale * 1.01
        // Cover page and direction only change a two-page layout.
        case #selector(toggleCoverPage(_:)), #selector(toggleRightToLeft(_:)): return settings.pages == .twoUp
        default: return true
        }
    }

    private func isChecked(_ action: Selector?) -> Bool {
        switch action {
        case #selector(zoomToActualSize(_:)): settings.zoom == .actualSize
        case #selector(zoomToFitPage(_:)): settings.zoom == .fitPage
        case #selector(zoomToFitWidth(_:)): settings.zoom == .fitWidth
        case #selector(showSinglePage(_:)): settings.pages == .single
        case #selector(showTwoPages(_:)): settings.pages == .twoUp
        case #selector(scrollContinuously(_:)): settings.scrolling == .continuous
        case #selector(scrollPageByPage(_:)): settings.scrolling == .paged
        case #selector(toggleCoverPage(_:)): settings.effectiveCoverPageAlone(hints: layoutHints)
        case #selector(toggleRightToLeft(_:)): settings.effectiveRightToLeft(hints: layoutHints)
        default: false
        }
    }
}

extension ReaderWindowController: NSWindowDelegate {}

extension ReaderWindowController: NSMenuItemValidation, NSToolbarItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.state = isChecked(menuItem.action) ? .on : .off
        return isEnabled(menuItem.action)
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        isEnabled(item.action)
    }
}

// MARK: Toolbar

extension NSToolbarItem.Identifier {
    static let zoomOut = Self("zoomOut")
    static let zoomIn = Self("zoomIn")
    static let zoomMenu = Self("zoomMenu")
    static let readingOptions = Self("readingOptions")
}

extension ReaderWindowController: NSToolbarDelegate {
    private func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "ReaderToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        return toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .zoomOut, .zoomIn, .zoomMenu, .readingOptions]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.zoomOut, .zoomIn, .zoomMenu, .readingOptions, .space, .flexibleSpace]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case .zoomOut:
            button(identifier, "Zoom Out", "minus.magnifyingglass", #selector(decreaseZoom(_:)), tip: "Zoom out (⌘−)")
        case .zoomIn:
            button(identifier, "Zoom In", "plus.magnifyingglass", #selector(increaseZoom(_:)), tip: "Zoom in (⌘+)")
        case .zoomMenu:
            menu(identifier, "Zoom", "arrow.up.left.and.arrow.down.right", ReaderCommands.zoomItems(), tip: "Actual size and fit options")
        case .readingOptions:
            menu(identifier, "Reading Options", "rectangle.split.2x1", ReaderCommands.readingOptionItems(), tip: "Pages, scrolling and rotation")
        default:
            nil
        }
    }

    private func button(_ identifier: NSToolbarItem.Identifier, _ label: String, _ symbol: String, _ action: Selector, tip: String) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = tip
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.isBordered = true
        item.action = action
        return item
    }

    private func menu(_ identifier: NSToolbarItem.Identifier, _ label: String, _ symbol: String, _ items: [NSMenuItem], tip: String) -> NSToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = tip
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        let menu = NSMenu(title: label)
        items.forEach(menu.addItem)
        item.menu = menu
        item.showsIndicator = true
        return item
    }
}

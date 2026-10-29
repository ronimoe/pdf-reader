import AppKit
import ReaderKit

/// Builds the menu bar in code (the project has no storyboards or nibs).
enum MainMenu {
    static func make() -> NSMenu {
        let appName = ProcessInfo.processInfo.processName
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: appMenu, title: appName)

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open…", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
        // NSDocumentController fills the submenu that holds Clear Menu.
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.addItem(withTitle: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
        fileMenu.addItem(submenu: recentMenu, title: "Open Recent")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        // Save goes through the incremental writer only (A1): in place, or a copy for signed,
        // certified, Reader-extended and read-only files.
        fileMenu.addItem(withTitle: "Save", action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        let saveAs = fileMenu.addItem(withTitle: "Save As…", action: #selector(NSDocument.saveAs(_:)), keyEquivalent: "s")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Export Bookmarks…", action: #selector(ReaderWindowController.exportBookmarks(_:)), keyEquivalent: "")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Print…", action: #selector(NSDocument.printDocument(_:)), keyEquivalent: "p")
        main.addItem(submenu: fileMenu, title: "File")

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        let findMenu = NSMenu(title: "Find")
        ReaderCommands.findItems().forEach(findMenu.addItem)
        editMenu.addItem(submenu: findMenu, title: "Find")
        main.addItem(submenu: editMenu, title: "Edit")

        let viewMenu = NSMenu(title: "View")
        ReaderCommands.sidebarItems().forEach(viewMenu.addItem)
        viewMenu.addItem(.separator())
        ReaderCommands.zoomItems().forEach(viewMenu.addItem)
        viewMenu.addItem(.separator())
        ReaderCommands.readingOptionItems().forEach(viewMenu.addItem)
        viewMenu.addItem(.separator())
        ReaderCommands.linkAndSplitItems().forEach(viewMenu.addItem)
        viewMenu.addItem(.separator())
        let toolbar = viewMenu.addItem(withTitle: "Show Toolbar", action: #selector(NSWindow.toggleToolbarShown(_:)), keyEquivalent: "t")
        toolbar.keyEquivalentModifierMask = [.command, .option]
        let fullScreen = viewMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        main.addItem(submenu: viewMenu, title: "View")

        let annotateMenu = AnnotateMenu(title: "Annotate")
        ReaderCommands.annotateItems().forEach(annotateMenu.addItem)
        main.addItem(submenu: annotateMenu, title: "Annotate")

        let goMenu = NSMenu(title: "Go")
        ReaderCommands.goItems().forEach(goMenu.addItem)
        main.addItem(submenu: goMenu, title: "Go")

        let bookmarksMenu = NSMenu(title: "Bookmarks")
        ReaderCommands.bookmarkItems().forEach(bookmarksMenu.addItem)
        main.addItem(submenu: bookmarksMenu, title: "Bookmarks")

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        main.addItem(submenu: windowMenu, title: "Window")
        NSApplication.shared.windowsMenu = windowMenu

        return main
    }
}

/// The Annotate menu. Its Delete Annotation item has a bare ⌫, and AppKit lets a *disabled*
/// item with a matching key equivalent swallow the key (measured on macOS 26). So the menu only
/// claims ⌫ while the reading area has focus and an annotation is selected; otherwise the key
/// goes on to whatever has focus, such as the search field.
nonisolated final class AnnotateMenu: NSMenu {
    /// Whether ⌫ should delete the selected annotation now. Tests replace it.
    nonisolated(unsafe) var claimsDeleteKey: @MainActor () -> Bool = {
        guard let view = NSApp.keyWindow?.firstResponder as? ReaderPDFView else { return false }
        return view.selectedAnnotation != nil
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if Self.isBareDelete(event) {
            // Key events arrive on the main thread; anywhere else, never claim the key.
            let check = claimsDeleteKey
            let claims = Thread.isMainThread && MainActor.assumeIsolated { check() }
            if !claims { return false }
        }
        return super.performKeyEquivalent(with: event)
    }

    static func isBareDelete(_ event: NSEvent) -> Bool {
        event.type == .keyDown && event.charactersIgnoringModifiers == String(UnicodeScalar(UInt8(NSDeleteCharacter)))
            && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}

import AppKit

/// The reading commands, built as menu items for both the menu bar and the
/// toolbar menus. Targets are nil, so each command reaches the key window's
/// `ReaderWindowController` through the responder chain and is validated
/// (enabled, checked) there.
///
/// The selectors deliberately avoid PDFView's own actions (`zoomIn:`,
/// `zoomOut:`, `goBack:`, `goForward:`, `goToNextPage:`…): PDFView, as first
/// responder, would take them first and bypass the settings and the history.
enum ReaderCommands {
    static func zoomItems() -> [NSMenuItem] {
        let zoomIn = item("Zoom In", #selector(ReaderWindowController.increaseZoom(_:)), "+")
        // ⌘= (unshifted) also zooms in, as in other Mac apps.
        let zoomInAlternate = item("Zoom In", #selector(ReaderWindowController.increaseZoom(_:)), "=")
        zoomInAlternate.isHidden = true
        zoomInAlternate.allowsKeyEquivalentWhenHidden = true
        return [
            item("Actual Size", #selector(ReaderWindowController.zoomToActualSize(_:)), "0"),
            zoomIn,
            zoomInAlternate,
            item("Zoom Out", #selector(ReaderWindowController.decreaseZoom(_:)), "-"),
            .separator(),
            item("Fit Page", #selector(ReaderWindowController.zoomToFitPage(_:)), "9"),
            item("Fit Width", #selector(ReaderWindowController.zoomToFitWidth(_:)), "9", [.command, .option]),
        ]
    }

    /// The reading options: Pages, Scrolling, Cover page, Right-to-left, Rotate.
    static func readingOptionItems() -> [NSMenuItem] {
        [
            .sectionHeader(title: "Pages"),
            item("Single Page", #selector(ReaderWindowController.showSinglePage(_:)), "1", [.command, .option]),
            item("Two Pages", #selector(ReaderWindowController.showTwoPages(_:)), "2", [.command, .option]),
            .sectionHeader(title: "Scrolling"),
            item("Continuous", #selector(ReaderWindowController.scrollContinuously(_:)), "3", [.command, .option]),
            item("Paged", #selector(ReaderWindowController.scrollPageByPage(_:)), "4", [.command, .option]),
            .separator(),
            item("Cover Page Alone", #selector(ReaderWindowController.toggleCoverPage(_:))),
            item("Right to Left", #selector(ReaderWindowController.toggleRightToLeft(_:))),
            .separator(),
            item("Rotate Left", #selector(ReaderWindowController.rotateDocumentLeft(_:)), "l"),
            item("Rotate Right", #selector(ReaderWindowController.rotateDocumentRight(_:)), "r"),
        ]
    }

    /// Show or hide the sidebar, and its sections (spec §4.1).
    static func sidebarItems() -> [NSMenuItem] {
        [
            item("Show Sidebar", #selector(ReaderWindowController.toggleReaderSidebar(_:)), "s", [.command, .control]),
            item("Thumbnails", #selector(ReaderWindowController.showThumbnails(_:))),
            item("Table of Contents", #selector(ReaderWindowController.showTableOfContents(_:))),
        ]
    }

    /// The Go menu: history (B2) and go to page.
    static func goItems() -> [NSMenuItem] {
        [
            item("Back", #selector(ReaderWindowController.navigateBack(_:)), "["),
            item("Forward", #selector(ReaderWindowController.navigateForward(_:)), "]"),
            .separator(),
            item("Go to Page…", #selector(ReaderWindowController.showGoToPage(_:)), "g", [.command, .option]),
        ]
    }

    /// Edit ▸ Find (B8).
    static func findItems() -> [NSMenuItem] {
        [
            item("Find…", #selector(ReaderWindowController.focusSearchField(_:)), "f"),
            item("Find Next", #selector(ReaderWindowController.showNextResult(_:)), "g"),
            item("Find Previous", #selector(ReaderWindowController.showPreviousResult(_:)), "g", [.command, .shift]),
            .separator(),
        ] + searchOptionItems()
    }

    /// Match Case and Whole Word, for the Find menu and the search field.
    static func searchOptionItems() -> [NSMenuItem] {
        [
            item("Match Case", #selector(ReaderWindowController.toggleMatchCase(_:))),
            item("Whole Words Only", #selector(ReaderWindowController.toggleWholeWord(_:))),
        ]
    }

    private static func item(
        _ title: String,
        _ action: Selector,
        _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}

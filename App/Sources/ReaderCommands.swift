import AppKit

/// The reading commands, built as menu items for both the View menu and the
/// toolbar menus. Targets are nil, so each command reaches the key window's
/// `ReaderWindowController` through the responder chain and is validated
/// (enabled, checked) there.
///
/// The selectors are deliberately not `zoomIn:`/`zoomOut:`: PDFView
/// implements those and, as first responder, would take them first.
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

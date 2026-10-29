import AppKit
import ReaderKit

/// What distraction-free mode hid, so leaving it puts each thing back as it was.
struct DistractionFreeChrome {
    /// Detached rather than hidden: toolbars sharing an identifier share their visibility, and a
    /// hidden toolbar is autosaved, so hiding it would hide every window's toolbar, for good.
    var toolbar: NSToolbar?
    var sidebarWasCollapsed: Bool
    var titleVisibility: NSWindow.TitleVisibility
    var titlebarAppearsTransparent: Bool
    /// Distraction-free mode entered full screen itself, so leaving it leaves full screen too.
    var enteredFullScreen: Bool
}

// MARK: Distraction-free mode (View ▸ Enter Distraction-Free Mode, ⇧⌘F)

extension ReaderWindowController {
    var isDistractionFree: Bool { distractionFree != nil }

    @objc func toggleDistractionFree(_ sender: Any?) {
        setDistractionFree(!isDistractionFree)
    }

    /// Hides the toolbar, the sidebar and the split's focus bar and close buttons so the pages
    /// fill the window, and optionally enters full screen (Settings ▸ General). Escape or the same
    /// command leaves. Every pane keeps its reading anchor (A3). Nothing is stored: the
    /// document's sidebar setting is untouched.
    func setDistractionFree(_ enabled: Bool) {
        guard enabled != isDistractionFree, let window else { return }
        dismissPreview()
        isMovingSidebarForSearch = true
        defer { isMovingSidebarForSearch = false }
        preservingEveryAnchor(panes[...]) {
            if enabled {
                let isFullScreen = window.styleMask.contains(.fullScreen)
                let goFullScreen = preferences.distractionFreeEntersFullScreen && !isFullScreen
                distractionFree = DistractionFreeChrome(
                    toolbar: window.toolbar,
                    sidebarWasCollapsed: sidebarItem.isCollapsed,
                    titleVisibility: window.titleVisibility,
                    titlebarAppearsTransparent: window.titlebarAppearsTransparent,
                    enteredFullScreen: goFullScreen
                )
                window.toolbar = nil
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                sidebarItem.isCollapsed = true
                updatePaneChrome()
                if goFullScreen { setFullScreen(window, true) }
            } else if let saved = distractionFree {
                distractionFree = nil
                window.toolbar = saved.toolbar
                window.titleVisibility = saved.titleVisibility
                window.titlebarAppearsTransparent = saved.titlebarAppearsTransparent
                sidebarItem.isCollapsed = saved.sidebarWasCollapsed
                updatePaneChrome()
                if saved.enteredFullScreen { setFullScreen(window, false) }
            }
            splitViewController.view.layoutSubtreeIfNeeded()
        }
        window.makeFirstResponder(focusedPane.view)
        if enabled { notice.show("Distraction-free. Press Escape to leave.") }
    }
}

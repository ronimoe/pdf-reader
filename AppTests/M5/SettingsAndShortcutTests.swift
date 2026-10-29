import AppKit
import ReaderCore
import ReaderUI
import SwiftUI
import Testing
@testable import Lectern

extension M5Tests {
    @MainActor
    @Suite struct SettingsTests {
        final class Harness {
            let preferences = ReaderPreferences.ephemeral()
            let updater = RecordingUpdater()
            lazy var updates = UpdateController(preferences: preferences, question: RecordingUpdateQuestion()) { [unowned self] in updater }
            var keepsWindows = false
            lazy var controller = SettingsWindowController(preferences: preferences, updates: updates, systemKeepsWindows: { [unowned self] in keepsWindows })
        }

        @Test func showsTheStoredPreferencesWithAnEmptyAuthor() {
            let h = Harness()
            let model = h.controller.model
            #expect(model.annotationAuthor.isEmpty, "never filled in from the Mac account (B4)")
            #expect(model.annotationAuthor != NSFullUserName() || NSFullUserName().isEmpty)
            #expect(model.previewsLinksOnHover)
            #expect(model.sessionRestore == .system)
            #expect(!model.checksForUpdatesAutomatically)
            #expect(model.annotationColor == .yellow)
            #expect(!model.distractionFreeEntersFullScreen)
        }

        @Test func changesGoStraightToThePreferences() {
            let h = Harness()
            let model = h.controller.model
            model.annotationAuthor = "R. Reader"
            model.annotationColor = .blue
            model.sessionRestore = .always
            model.distractionFreeEntersFullScreen = true
            model.previewsLinksOnHover = false
            #expect(h.preferences.annotationAuthor == "R. Reader")
            #expect(h.preferences.annotationColor == .blue)
            #expect(h.preferences.sessionRestore == .always)
            #expect(h.preferences.distractionFreeEntersFullScreen)
            #expect(!h.preferences.previewsLinksOnHover)
        }

        @Test func theHoverSettingIsTheViewMenusPreference() throws {
            let h = Harness()
            let reader = try M5Harness(TestPDF.make(pageCount: 2)!, preferences: h.preferences)
            defer { reader.close() }
            reader.controller.togglePreviewLinksOnHover(nil)
            #expect(!h.controller.model.previewsLinksOnHover, "Settings follows the View menu")
            h.controller.model.previewsLinksOnHover = true
            #expect(reader.view.previewsOnHover, "and the View menu follows Settings")
        }

        @Test func updateSettingsDriveTheUpdater() {
            let h = Harness()
            h.controller.model.checksForUpdatesAutomatically = true
            #expect(h.preferences.checksForUpdatesAutomatically == true)
            #expect(h.updater.automaticallyChecks)
            h.controller.model.onCheckNow()
            #expect(h.updater.checks == 1)
            h.controller.model.checksForUpdatesAutomatically = false
            #expect(!h.updater.automaticallyChecks)
        }

        @Test func theSystemCloseWindowsSettingIsShown() {
            let h = Harness()
            h.keepsWindows = true
            h.controller.load()
            #expect(h.controller.model.systemKeepsWindows)
        }

        @Test func commandCommaOpensSettings() throws {
            let item = try #require(allMenuItems(MainMenu.make()).first { $0.action == #selector(AppDelegate.showSettings(_:)) })
            #expect(item.keyEquivalent == "," && item.keyEquivalentModifierMask == .command)
            #expect(item.title == "Settings…")
        }

        @Test func theSettingsWindowIsSmallNativeAndNeverRestored() throws {
            let h = Harness()
            let window = try #require(h.controller.window)
            #expect(window.title == "Settings")
            #expect(!window.isRestorable)
            #expect(window.tabbingMode == .disallowed)
            #expect(window.contentViewController is NSHostingController<SettingsView>)
        }
    }

    @MainActor
    @Suite struct KeyboardShortcutMapTests {
        /// The items the map must list: the same rule as the uniqueness test's view of the menu,
        /// visible items with a key equivalent, in visible submenus.
        private func visibleShortcutItems(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { item -> [NSMenuItem] in
                if let submenu = item.submenu { return item.isHidden ? [] : visibleShortcutItems(submenu) }
                return !item.isHidden && !item.keyEquivalent.isEmpty ? [item] : []
            }
        }

        @Test func everyVisibleShortcutInTheRunningMenuIsListed() throws {
            let menu = try #require(NSApp.mainMenu)
            let groups = KeyboardShortcutCatalog.groups(from: menu)
            let entries = groups.flatMap(\.entries)
            let items = visibleShortcutItems(menu)
            #expect(entries.count == items.count)
            for item in items {
                let keys = KeyboardShortcutCatalog.keys(for: item)
                #expect(entries.contains { $0.title.hasSuffix(item.title) && $0.keys == keys }, "\(item.title) \(keys) missing")
            }
            #expect(groups.map(\.menu).first == ProcessInfo.processInfo.processName, "grouped by menu, in menu order")
        }

        @Test func theListIsBuiltFromTheMenuItIsGiven() throws {
            let menu = MainMenu.make()
            let entries = KeyboardShortcutCatalog.groups(from: menu).flatMap(\.entries)
            func entry(_ title: String) -> KeyboardShortcutCatalog.Entry? { entries.first { $0.title == title } }
            #expect(entry("Show Sidebar")?.keys == "⌃⌘S")
            #expect(entry("Add Bookmark")?.keys == "⌘D")
            #expect(entry("Enter Distraction-Free Mode")?.keys == "⇧⌘F")
            #expect(entry("Focus Links")?.keys == "⌥⇥")
            #expect(entry("Fit Width")?.keys == "⌥⌘9")
            #expect(entry("Find ▸ Find Next")?.keys == "⌘G")
            #expect(entry("Colour ▸ Yellow")?.keys == "⌃⌘1")
            #expect(entry("Delete Annotation")?.keys == "⌫")
            #expect(entry("Next Annotation")?.keys == "⌥⌘↓")
            #expect(entry("Keyboard Shortcuts")?.keys == "⌘/")
            #expect(entry("Settings…")?.keys == "⌘,")
            // Hidden alternates work but aren't listed twice.
            #expect(entries.filter { $0.title == "Zoom In" }.count == 1)
            // Adding a menu item adds a line: nothing is hard-coded.
            let extra = NSMenuItem(title: "Probe Command", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "j")
            menu.items.first?.submenu?.addItem(extra)
            #expect(KeyboardShortcutCatalog.groups(from: menu).flatMap(\.entries).contains { $0.title == "Probe Command" && $0.keys == "⌘J" })
        }

        @Test func spokenLabelsNameTheKeys() {
            #expect(KeyboardShortcutsView.spoken("⌃⌘S") == "Control Command S")
            #expect(KeyboardShortcutsView.spoken("⌥⇥") == "Option Tab")
        }

        @Test func helpMenuOpensTheMap() throws {
            let item = try #require(allMenuItems(MainMenu.make()).first { $0.action == #selector(AppDelegate.showKeyboardShortcuts(_:)) })
            #expect(item.keyEquivalent == "/" && item.keyEquivalentModifierMask == .command)
            let controller = KeyboardShortcutsWindowController(menu: { MainMenu.make() })
            #expect(controller.groups.contains { $0.menu == "Bookmarks" })
            #expect(controller.window?.isRestorable == false)
        }
    }

    @MainActor
    @Suite struct DistractionFreeTests {
        private func harness(pages: Int = 6) throws -> M5Harness {
            try M5Harness(TestPDF.make(pageCount: pages)!)
        }

        @Test func hidesTheChromeKeepsThePlaceAndComesBack() throws {
            let h = try harness()
            defer { h.close() }
            h.controller.setSidebarVisible(true)
            let toolbar = try #require(h.window.toolbar)
            let place = h.read(at: 3, y: 400)
            let storedSidebar = h.controller.settings.sidebar

            h.controller.toggleDistractionFree(nil)
            #expect(h.controller.isDistractionFree)
            #expect(h.window.toolbar == nil)
            #expect(!h.controller.isSidebarVisible)
            #expect(h.window.titleVisibility == .hidden)
            #expect(h.view.currentAnchor?.isSamePlace(as: place) == true, "the reading anchor is kept (A3)")
            #expect(h.controller.settings.sidebar == storedSidebar, "hiding the sidebar here isn't the user's choice to store")

            h.controller.toggleDistractionFree(nil)
            #expect(!h.controller.isDistractionFree)
            #expect(h.window.toolbar === toolbar)
            #expect(h.controller.isSidebarVisible)
            #expect(h.window.titleVisibility == .visible)
            #expect(h.view.currentAnchor?.isSamePlace(as: place) == true)
            #expect(h.controller.settings.sidebar == storedSidebar)
        }

        @Test func escapeLeaves() throws {
            let h = try harness()
            defer { h.close() }
            h.controller.setDistractionFree(true)
            #expect(h.view.onCancel?() == true)
            #expect(!h.controller.isDistractionFree)
            h.controller.setDistractionFree(true)
            h.controller.cancelOperation(nil)
            #expect(!h.controller.isDistractionFree)
            #expect(h.view.onCancel?() == false, "Escape does nothing more once out")
        }

        @Test func theSplitsFocusBarAndCloseButtonsHide() throws {
            let h = try harness()
            defer { h.close() }
            h.controller.openSplit()
            let container = try #require(h.controller.paneContainers[.primary])
            #expect(container.showsFocus)
            h.controller.setDistractionFree(true)
            #expect(!container.showsFocus)
            #expect(container.closeButton.isHidden)
            h.controller.setDistractionFree(false)
            #expect(container.showsFocus)
            #expect(!container.closeButton.isHidden)
        }

        @Test func fullScreenOnlyWhenSettingsSaySo() throws {
            let h = try harness()
            defer { h.close() }
            var calls: [Bool] = []
            h.controller.setFullScreen = { _, on in calls.append(on) }
            h.controller.setDistractionFree(true)
            h.controller.setDistractionFree(false)
            #expect(calls.isEmpty)
            h.preferences.distractionFreeEntersFullScreen = true
            h.controller.setDistractionFree(true)
            h.controller.setDistractionFree(false)
            #expect(calls == [true, false])
        }

        @Test func findLeavesItBecauseTheFieldIsInTheToolbar() throws {
            let h = try harness()
            defer { h.close() }
            h.controller.setDistractionFree(true)
            h.controller.focusSearchField(nil)
            #expect(!h.controller.isDistractionFree)
            #expect(h.window.toolbar != nil)
        }

        @Test func theViewMenuItemNamesTheModeAndHasAShortcut() throws {
            let h = try harness()
            defer { h.close() }
            let item = try #require(allMenuItems(MainMenu.make()).first { $0.action == #selector(ReaderWindowController.toggleDistractionFree(_:)) })
            #expect(item.keyEquivalent == "f" && item.keyEquivalentModifierMask == [.command, .shift])
            _ = h.controller.validateMenuItem(item)
            #expect(item.title == "Enter Distraction-Free Mode")
            h.controller.setDistractionFree(true)
            _ = h.controller.validateMenuItem(item)
            #expect(item.title == "Exit Distraction-Free Mode")
        }
    }
}

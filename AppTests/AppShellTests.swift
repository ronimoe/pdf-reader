import AppKit
import ReaderKit
import Testing
@testable import Lectern

@MainActor
@Suite struct MainMenuTests {
    private let menu = MainMenu.make()

    private func item(_ action: Selector, key: String? = nil) -> NSMenuItem? {
        allItems(menu).first { $0.action == action && (key == nil || $0.keyEquivalent == key) }
    }

    private static let shortcuts: [(Selector, String, NSEvent.ModifierFlags)] = [
        (#selector(ReaderWindowController.zoomToActualSize(_:)), "0", NSEvent.ModifierFlags.command),
        (#selector(ReaderWindowController.increaseZoom(_:)), "+", .command),
        (#selector(ReaderWindowController.increaseZoom(_:)), "=", .command),
        (#selector(ReaderWindowController.decreaseZoom(_:)), "-", .command),
        (#selector(ReaderWindowController.zoomToFitPage(_:)), "9", .command),
        (#selector(ReaderWindowController.zoomToFitWidth(_:)), "9", [.command, .option]),
        (#selector(ReaderWindowController.showSinglePage(_:)), "1", [.command, .option]),
        (#selector(ReaderWindowController.showTwoPages(_:)), "2", [.command, .option]),
        (#selector(ReaderWindowController.scrollContinuously(_:)), "3", [.command, .option]),
        (#selector(ReaderWindowController.scrollPageByPage(_:)), "4", [.command, .option]),
        (#selector(ReaderWindowController.rotateDocumentLeft(_:)), "l", .command),
        (#selector(ReaderWindowController.rotateDocumentRight(_:)), "r", .command),
        (#selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        (#selector(NSDocument.printDocument(_:)), "p", .command),
        (#selector(ReaderWindowController.focusLinks(_:)), "\t", .option),
        (#selector(ReaderWindowController.toggleSplitView(_:)), "t", [.command, .control]),
        (#selector(ReaderWindowController.focusOtherPane(_:)), "o", [.command, .control]),
    ]

    @Test func everyCommandHasItsShortcut() throws {
        for (action, key, modifiers) in Self.shortcuts {
            let item = try #require(item(action, key: key), "\(action) \(key)")
            #expect(item.keyEquivalentModifierMask == modifiers, "\(action)")
        }
    }

    @Test func viewMenuHoldsTheLayoutToggles() throws {
        let view = try #require(menu.items.first { $0.title == "View" }?.submenu)
        let actions = Set(view.items.compactMap(\.action))
        #expect(actions.contains(#selector(ReaderWindowController.toggleCoverPage(_:))))
        #expect(actions.contains(#selector(ReaderWindowController.toggleRightToLeft(_:))))
        #expect(actions.contains(#selector(NSWindow.toggleToolbarShown(_:))))
    }

    @Test func shortcutsAreUnique() throws {
        // Both as built and as running, after AppKit adds its own items
        // (full screen, tab bar) to the live menu.
        for menu in [menu, try #require(NSApp.mainMenu)] {
            let shortcuts = allItems(menu)
                .filter { !$0.keyEquivalent.isEmpty }
                .map { "\($0.keyEquivalentModifierMask.rawValue)-\($0.keyEquivalent)" }
            #expect(Set(shortcuts).count == shortcuts.count, "\(shortcuts.sorted())")
            let fullScreen = allItems(menu).filter { $0.action == #selector(NSWindow.toggleFullScreen(_:)) }
            // On macOS 26 AppKit adds its own Globe-F item and keeps ⌃⌘F as a hidden alternate.
            #expect(fullScreen.filter { !$0.isHidden }.count == 1)
        }
    }

    @Test func fileMenuHasPrintAndOpenRecentButNoSave() throws {
        let file = try #require(menu.items.first { $0.title == "File" }?.submenu)
        #expect(file.items.contains { $0.action == #selector(NSDocument.printDocument(_:)) })
        #expect(file.items.contains { $0.submenu?.items.contains { $0.action == #selector(NSDocumentController.clearRecentDocuments(_:)) } == true })
        #expect(!file.items.contains { $0.action == #selector(NSDocument.save(_:)) })
    }

    private func allItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { [$0] + ($0.submenu.map(allItems) ?? []) }
    }
}

@MainActor
@Suite struct EmptyStateTests {
    @Test func showsOnlyWhileNoDocumentIsOpen() {
        let recent = URL(fileURLWithPath: "/tmp/Recent Paper.pdf")
        let controller = EmptyStateController(recentURLs: { [recent] }, openDocument: {}, openURLs: { _ in })
        controller.documentsDidChange(count: 0)
        #expect(controller.isShown)
        #expect(controller.model.recents.map(\.url) == [recent])
        #expect(controller.model.recents.first?.name == "Recent Paper")

        controller.documentsDidChange(count: 1)
        #expect(!controller.isShown)
        controller.documentsDidChange(count: 0)
        #expect(controller.isShown)
        controller.hide()
    }

    @Test func offersOpenDocumentAndOpensRecents() {
        var openPanels = 0
        var opened: [URL] = []
        let controller = EmptyStateController(
            recentURLs: { [] },
            openDocument: { openPanels += 1 },
            openURLs: { opened += $0 }
        )
        controller.model.onOpenDocument()
        let url = URL(fileURLWithPath: "/tmp/a.pdf")
        controller.model.onOpenURLs([url])
        #expect(openPanels == 1)
        #expect(opened == [url])
    }

    @Test func dropsAcceptOnlyPDFFiles() throws {
        let directory = FileManager.default.temporaryDirectory
        let pdf = directory.appending(path: "Dropped-\(UUID().uuidString).pdf")
        let text = directory.appending(path: "Dropped-\(UUID().uuidString).txt")
        try #require(TestPDF.make(pageCount: 1)).write(to: pdf)
        try Data("hello".utf8).write(to: text)
        let pasteboard = NSPasteboard(name: .init("LecternTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([pdf as NSURL, text as NSURL])
        let urls = ReaderPDFView.pdfURLs(on: pasteboard).map(\.standardizedFileURL)
        #expect(urls == [pdf.standardizedFileURL])
    }

    @Test func emptyStateWindowNeverTakesDocumentTabs() throws {
        let controller = EmptyStateController(recentURLs: { [] }, openDocument: {}, openURLs: { _ in })
        controller.show()
        defer { controller.hide() }
        let window = try #require(controller.window)
        #expect(window.tabbingMode == .disallowed)
        #expect(window.isVisible)
    }
}

/// Exercises the real shared document controller. Serialized: it opens and
/// closes documents in the running app.
@MainActor
@Suite(.serialized) struct DocumentControllerTests {
    @Test func sharedControllerIsTheReaderSubclass() {
        #expect(NSDocumentController.shared is ReaderDocumentController)
    }

    @Test func untitledDocumentsAreNeverCreated() {
        #expect(throws: (any Error).self) {
            try NSDocumentController.shared.makeUntitledDocument(ofType: "com.adobe.pdf")
        }
    }

    @Test func reopeningAnOpenFileBringsItsTabForward() async throws {
        let controller = try #require(NSDocumentController.shared as? ReaderDocumentController)
        controller.recordsRecentDocuments = false
        defer { controller.recordsRecentDocuments = true }
        let first = try writeFixture("First")
        let second = try writeFixture("Second")

        let (a, _) = try await controller.openDocument(withContentsOf: first, display: true)
        let (b, _) = try await controller.openDocument(withContentsOf: second, display: true)
        defer {
            a.close()
            b.close()
        }
        let aWindow = try #require(a.windowControllers.first?.window)
        let bWindow = try #require(b.windowControllers.first?.window)
        #expect(aWindow.isVisible && bWindow.isVisible)

        let (again, alreadyOpen) = try await controller.openDocument(withContentsOf: first, display: true)
        #expect(again === a)
        #expect(alreadyOpen)
        #expect(controller.documents.filter { $0.fileURL == first }.count == 1)
        if let group = aWindow.tabGroup, group.windows.contains(bWindow) {
            #expect(group.selectedWindow === aWindow)
        } else {
            #expect(NSApp.orderedWindows.firstIndex(of: aWindow)! < NSApp.orderedWindows.firstIndex(of: bWindow)!)
        }
    }

    @Test func emptyStateHidesWhileADocumentIsOpenAndReturnsAfter() async throws {
        let controller = try #require(NSDocumentController.shared as? ReaderDocumentController)
        let emptyState = try #require((NSApp.delegate as? AppDelegate)?.emptyState)
        controller.recordsRecentDocuments = false
        defer { controller.recordsRecentDocuments = true }

        let (document, _) = try await controller.openDocument(withContentsOf: try writeFixture("Empty State"), display: true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!emptyState.isShown)

        document.close()
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.documents.isEmpty == emptyState.isShown)
    }

    private func writeFixture(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(name)-\(UUID().uuidString).pdf")
        try #require(TestPDF.make(pageCount: 2)).write(to: url)
        return url
    }
}

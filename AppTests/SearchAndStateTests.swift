import AppKit
import PDFKit
import Persistence
import ReaderCore
import ReaderKit
import ReaderUI
import Testing
@testable import Lectern

@MainActor
private func waitForSearch(_ harness: NavigationHarness) {
    spin { harness.controller.search?.isSearching == false }
}

// MARK: Search (B8)

@MainActor
@Suite struct SearchTests {
    @Test func resultsArriveWithoutBlockingAndAreCounted() throws {
        let harness = try NavigationHarness(FixturePDF.prose(pages: 40))
        defer { harness.close() }
        harness.controller.startSearch("reading")
        let search = try #require(harness.controller.search)
        // beginFindString returns at once; results come in afterwards.
        #expect(search.isSearching)
        #expect(search.results.isEmpty)
        waitForSearch(harness)
        #expect(search.results.count == 40 * 30)
        #expect(search.progress == 1)
        harness.controller.searchSection.reload()
        #expect(harness.controller.searchSection.statusLabel.stringValue == "1200 results")
        #expect(harness.pdfView.highlightedSelections?.count == 1200)
        #expect(harness.controller.sidebar.visibleSection == .search)
        #expect(harness.controller.isSidebarVisible)
    }

    @Test func ignoresCaseAndAccentsByDefault() throws {
        let harness = try NavigationHarness(FixturePDF.make(pageTexts: ["Café cafe CAFE", "cafés and a cat"]))
        defer { harness.close() }
        harness.controller.startSearch("cafe")
        waitForSearch(harness)
        #expect(harness.controller.search?.results.count == 4)

        harness.controller.toggleMatchCase(nil)
        waitForSearch(harness)
        // "cafe" and the start of "cafés": accents are still ignored, but
        // "Café" and "CAFE" differ in case.
        #expect(harness.controller.search?.results.count == 2)
        harness.controller.toggleMatchCase(nil)

        harness.controller.toggleWholeWord(nil)
        waitForSearch(harness)
        // "cafés" no longer counts.
        #expect(harness.controller.search?.results.count == 3)
    }

    @Test func resultsListTheTextAroundEachMatch() throws {
        let harness = try NavigationHarness(FixturePDF.book())
        defer { harness.close() }
        harness.controller.startSearch("needle")
        waitForSearch(harness)
        let section = harness.controller.searchSection
        section.reload()
        #expect(section.tableView.numberOfRows == 8)
        let cell = try #require(section.tableView.view(atColumn: 0, row: 2, makeIfNecessary: true))
        let label = try #require(cell.accessibilityLabel())
        // Labels are the document's own: the third page is "1".
        #expect(label.hasPrefix("Page 1:"))
        #expect(label.contains("with a needle and"))
    }

    @Test func nextAndPreviousStepThroughResultsAndWrap() throws {
        let harness = try NavigationHarness(FixturePDF.book())
        defer { harness.close() }
        harness.controller.startSearch("needle")
        waitForSearch(harness)
        harness.controller.showNextResult(nil)
        #expect(harness.controller.currentResultIndex == 0)
        #expect(harness.pdfView.currentSelection?.string == "needle")
        harness.controller.showNextResult(nil)
        #expect(harness.controller.currentResultIndex == 1)
        #expect(harness.selectedPageIndex == 1)
        harness.controller.showPreviousResult(nil)
        harness.controller.showPreviousResult(nil)
        #expect(harness.controller.currentResultIndex == 7)
        #expect(harness.selectedPageIndex == 7)
        // The result is shown below the toolbar.
        let selection = try #require(harness.pdfView.currentSelection)
        let page = try #require(selection.pages.first)
        let rect = harness.pdfView.convert(selection.bounds(for: page), from: page)
        #expect(rect.maxY < harness.pdfView.bounds.height - harness.pdfView.safeAreaInsets.top)
        #expect(rect.minY > 0)
    }

    @Test func aSearchSessionAddsOneHistoryEntryThePositionBeforeIt() throws {
        let harness = try NavigationHarness(FixturePDF.prose(pages: 30))
        defer { harness.close() }
        let place = harness.read(at: 2)
        harness.controller.startSearch("Page 2")
        harness.controller.startSearch("Page 25 line")
        waitForSearch(harness)
        for _ in 0..<5 { harness.controller.showNextResult(nil) }
        #expect(harness.selectedPageIndex == 24)
        #expect(harness.history.backList.count == 1)
        harness.controller.cancelOperation(nil)
        #expect(harness.history.backList.count == 1)
        harness.controller.navigateBack(nil)
        expectKeptPlace(place, in: harness.pdfView)
    }

    @Test func escapeEndsTheSearch() throws {
        let harness = try NavigationHarness(FixturePDF.book())
        defer { harness.close() }
        harness.controller.showTableOfContents(nil)
        harness.controller.toggleReaderSidebar(nil)
        #expect(!harness.controller.isSidebarVisible)
        harness.controller.startSearch("needle")
        waitForSearch(harness)
        harness.controller.showNextResult(nil)
        #expect(harness.controller.isSidebarVisible)

        harness.controller.cancelOperation(nil)
        #expect(!harness.controller.isSearching)
        #expect(harness.pdfView.highlightedSelections?.isEmpty != false)
        #expect(!harness.controller.sidebar.availableSections.contains(.search))
        // The sidebar goes back to how the user left it.
        #expect(!harness.controller.isSidebarVisible)
        #expect(harness.controller.sidebar.visibleSection == .outline)
        #expect(!harness.controller.settings.sidebar.isVisible)
    }

    @Test func escapeInTheReadingAreaReachesTheWindow() throws {
        let harness = try NavigationHarness(FixturePDF.book())
        defer { harness.close() }
        harness.controller.startSearch("needle")
        waitForSearch(harness)
        let window = try #require(harness.controller.window)
        window.makeFirstResponder(harness.pdfView)
        // What Escape sends, through the real responder chain.
        #expect(harness.pdfView.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: nil))
        #expect(!harness.controller.isSearching)

        // And the key itself, which PDFView would otherwise keep.
        harness.controller.startSearch("needle")
        let escape = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        ))
        harness.pdfView.keyDown(with: escape)
        #expect(!harness.controller.isSearching)
    }

    @Test func findPutsTheSearchFieldBackIfTheToolbarLostIt() throws {
        let harness = try NavigationHarness(FixturePDF.prose(pages: 2))
        defer { harness.close() }
        let toolbar = try #require(harness.controller.window?.toolbar)
        if let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == .search }) {
            toolbar.removeItem(at: index)
        }
        harness.controller.focusSearchField(nil)
        #expect(toolbar.items.contains { $0.itemIdentifier == .search })
        #expect(harness.controller.searchField != nil)
    }

    @Test func aDocumentWithoutTextSaysSo() async throws {
        let harness = try NavigationHarness(FixturePDF.make(pageTexts: [nil, nil, nil]))
        defer { harness.close() }
        harness.controller.startSearch("anything")
        await harness.controller.waitForTextInventory()
        await eventually { harness.controller.search?.isSearching == false }
        let summary = try #require(harness.controller.search?.summary)
        #expect(summary.status == "This document has no searchable text", "\(summary)")
        #expect(summary.textCoverageNote == nil)
        #expect(harness.controller.search?.isSearching == false)
    }

    @Test func aPartlyScannedDocumentSaysHowManyPagesHaveNoText() async throws {
        let harness = try NavigationHarness(FixturePDF.make(pageTexts: ["one word", nil, nil]))
        defer { harness.close() }
        harness.controller.startSearch("word")
        await harness.controller.waitForTextInventory()
        await eventually { harness.controller.search?.isSearching == false }
        let summary = try #require(harness.controller.search?.summary)
        #expect(summary.status == "1 result")
        #expect(summary.textCoverageNote == "2 pages have no searchable text and can’t be searched.")
        harness.controller.searchSection.reload()
        #expect(!harness.controller.searchSection.noteLabel.isHidden)
    }

    @Test func nothingFoundIsNoResults() async throws {
        let harness = try NavigationHarness(FixturePDF.prose(pages: 3))
        defer { harness.close() }
        harness.controller.startSearch("zebra")
        await harness.controller.waitForTextInventory()
        await eventually { harness.controller.search?.isSearching == false }
        #expect(harness.controller.search?.summary.status == "No results")
        #expect(!harness.controller.validateMenuItem(NSMenuItem(title: "", action: #selector(ReaderWindowController.showNextResult(_:)), keyEquivalent: "")))
    }
}

// MARK: Stored state (A2, Journey A step 5, Journey D step 6)

@MainActor
@Suite struct StoredStateTests {
    @Test func reopeningRestoresPositionSettingsSidebarAndHistory() throws {
        let folder = try TemporaryFolder()
        let file = try folder.write(FixturePDF.prose(pages: 30, id: "0A0B0C0D"), to: "Long Read.pdf")

        let first = try NavigationHarness(file: file, store: folder.store())
        first.controller.showTwoPages(nil)
        first.controller.rotateDocumentRight(nil)
        first.controller.showTableOfContents(nil)
        first.pane.jump(toPageAt: 20)
        let place = first.read(at: 12)
        first.controller.saveAnchor()
        let settings = first.controller.settings
        first.close()

        // A fresh store, as after relaunching.
        let second = try NavigationHarness(file: file, store: folder.store())
        defer { second.close() }
        #expect(second.controller.settings == settings)
        #expect(second.pdfView.displayMode == .twoUpContinuous)
        #expect(second.document.pdfDocument?.page(at: 0)?.rotation == 90)
        #expect(second.controller.isSidebarVisible)
        #expect(second.controller.sidebar.visibleSection == .outline)
        #expect(second.history.backList.count == 1)
        expectKeptPlace(place, in: second.pdfView)
    }

    @Test func closingWritesTheStateOut() throws {
        let folder = try TemporaryFolder()
        let file = try folder.write(FixturePDF.prose(pages: 10), to: "a.pdf")
        let store = folder.store()
        let harness = try NavigationHarness(file: file, store: store)
        let id = try #require(harness.controller.storedDocumentID)
        harness.read(at: 6)
        harness.close()
        // A fresh store reads only what reached the disk.
        let written = try #require(folder.store().state(for: id))
        #expect(written.anchor?.pageIndex == 6)
    }

    @Test func aDocumentWithAnOutlineFirstOpensOnTheTableOfContents() throws {
        let folder = try TemporaryFolder()
        let file = try folder.write(FixturePDF.book(), to: "book.pdf")
        let harness = try NavigationHarness(file: file, store: folder.store())
        defer { harness.close() }
        #expect(harness.controller.sidebar.visibleSection == .outline)
    }

    @Test func documentsTestsOpenNeverReachTheRealContainer() throws {
        // Tests that open files through NSDocumentController use the shared
        // store; while hosting tests it lives in a throwaway folder.
        #expect(AppEnvironment.isHostingTests)
        let directory = try #require(AppEnvironment.stateStore?.directory)
        #expect(!directory.path.contains("Application Support"))
        #expect(directory.lastPathComponent.hasPrefix("LecternTestState-"))
    }

    @Test func inMemoryDocumentsStoreNothing() throws {
        let harness = try NavigationHarness(FixturePDF.prose(pages: 2))
        defer { harness.close() }
        #expect(harness.controller.storedDocumentID == nil)
    }
}

// MARK: Changes on disk (B7)

@MainActor
@Suite struct FileChangeTests {
    @Test func aChangedFileReloadsSilentlyAndSaysSo() async throws {
        let folder = try TemporaryFolder()
        let file = try folder.write(FixturePDF.prose(pages: 10), to: "draft.pdf")
        let harness = try NavigationHarness(file: file, store: folder.store())
        defer { harness.close() }
        let place = harness.read(at: 4)
        let old = harness.pdfView.document
        #expect(await !harness.document.reloadFromDiskIfChanged())

        try FixturePDF.prose(pages: 12).write(to: file)
        #expect(await harness.document.reloadFromDiskIfChanged())
        #expect(harness.pdfView.document !== old)
        #expect(harness.pdfView.document?.pageCount == 12)
        #expect(harness.document.originalData == (try Data(contentsOf: file)))
        #expect(harness.controller.notice.message == "Reloaded")
        expectKeptPlace(place, in: harness.pdfView)
        // The notice goes by itself.
        await eventually(timeout: 3) { harness.controller.notice.message == nil }
        #expect(harness.controller.notice.isHidden)
    }

    @Test func aCoordinatedWriteIsNoticed() async throws {
        let folder = try TemporaryFolder()
        let file = try folder.write(FixturePDF.prose(pages: 3), to: "watched.pdf")
        let harness = try NavigationHarness(file: file, store: folder.store())
        defer { harness.close() }
        harness.document.reloadDelay = 0.05
        // As the app opens it: through the document controller, where
        // NSDocument registers itself as the file's presenter.
        NSDocumentController.shared.addDocument(harness.document)

        // Another app's write, off the main thread as it would be: a
        // coordinated write waits for the document to step aside, which
        // happens on the main queue.
        let changed = FixturePDF.prose(pages: 5)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                var error: NSError?
                NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: file, options: .forReplacing, error: &error) { url in
                    try? changed.write(to: url)
                }
                done.resume()
            }
        }
        await eventually { harness.pdfView.document?.pageCount == 5 }
        #expect(harness.pdfView.document?.pageCount == 5)
    }

    @Test func historyIsClampedToTheNewPageCount() throws {
        let harness = try NavigationHarness(FixturePDF.prose(pages: 20))
        defer { harness.close() }
        harness.read(at: 18)
        harness.pane.jump(toPageAt: 2)
        let shorter = FixturePDF.prose(pages: 5)
        harness.document.reload(with: shorter, pdf: try #require(PDFDocument(data: shorter)))
        #expect(harness.history.backList.map(\.pageIndex) == [4])
    }

    @Test func aRunningSearchIsRepeatedOnTheNewContent() throws {
        let harness = try NavigationHarness(FixturePDF.prose(pages: 3))
        defer { harness.close() }
        harness.controller.startSearch("Page 2 line 1 ")
        waitForSearch(harness)
        harness.controller.showNextResult(nil)
        let entries = harness.history.backList.count
        let longer = FixturePDF.prose(pages: 6)
        harness.document.reload(with: longer, pdf: try #require(PDFDocument(data: longer)))
        waitForSearch(harness)
        #expect(harness.controller.search?.document === harness.pdfView.document)
        #expect(harness.controller.search?.results.isEmpty == false)
        #expect(harness.history.backList.count == entries)
    }

    @Test func aDeletedFileStaysOpenWithANotice() async throws {
        let folder = try TemporaryFolder()
        let file = try folder.write(FixturePDF.prose(pages: 3), to: "gone.pdf")
        let harness = try NavigationHarness(file: file, store: folder.store())
        defer { harness.close() }
        try FileManager.default.removeItem(at: file)
        #expect(await !harness.document.reloadFromDiskIfChanged())
        #expect(harness.document.fileWasRemoved)
        #expect(harness.controller.isShowingContent)
        #expect(harness.controller.notice.message?.contains("was deleted or moved to the Trash") == true)
        // It lasts.
        await eventually(timeout: 2) { harness.controller.notice.message == nil }
        #expect(harness.controller.notice.message != nil)
    }

    @Test func movingToTheTrashCountsAsRemoved() async throws {
        let harness = try NavigationHarness(FixturePDF.prose(pages: 2))
        defer { harness.close() }
        harness.document.presentedItemDidMove(to: URL(fileURLWithPath: "/Users/someone/.Trash/gone.pdf"))
        await eventually { harness.document.fileWasRemoved }
        #expect(harness.controller.notice.message != nil)
    }
}

// MARK: Commands

@MainActor
@Suite struct NavigationCommandTests {
    private let menu = MainMenu.make()

    private func allItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { [$0] + ($0.submenu.map(allItems) ?? []) }
    }

    private static let shortcuts: [(Selector, String, NSEvent.ModifierFlags)] = [
        (#selector(ReaderWindowController.toggleReaderSidebar(_:)), "s", [.command, .control]),
        (#selector(ReaderWindowController.navigateBack(_:)), "[", .command),
        (#selector(ReaderWindowController.navigateForward(_:)), "]", .command),
        (#selector(ReaderWindowController.showGoToPage(_:)), "g", [.command, .option]),
        (#selector(ReaderWindowController.focusSearchField(_:)), "f", .command),
        (#selector(ReaderWindowController.showNextResult(_:)), "g", .command),
        (#selector(ReaderWindowController.showPreviousResult(_:)), "g", [.command, .shift]),
    ]

    @Test func everyNavigationCommandHasItsShortcut() throws {
        for (action, key, modifiers) in Self.shortcuts {
            let item = try #require(allItems(menu).first { $0.action == action }, "\(action)")
            #expect(item.keyEquivalent == key, "\(action)")
            #expect(item.keyEquivalentModifierMask == modifiers, "\(action)")
        }
    }

    @Test func theGoMenuHoldsHistoryAndGoToPage() throws {
        let go = try #require(menu.items.first { $0.title == "Go" }?.submenu)
        let actions = go.items.compactMap(\.action)
        #expect(actions == [
            #selector(ReaderWindowController.navigateBack(_:)),
            #selector(ReaderWindowController.navigateForward(_:)),
            #selector(ReaderWindowController.showGoToPage(_:)),
            #selector(ReaderWindowController.showNextAnnotation(_:)),
            #selector(ReaderWindowController.showPreviousAnnotation(_:)),
        ])
    }

    @Test func pdfViewHandlesNoneOfTheNewCommandsItself() throws {
        // PDFView is first responder; a selector it implements would never
        // reach the window controller (as goBack: and zoomIn: would).
        let view = ReaderPDFView(frame: .zero)
        for item in allItems(menu) {
            guard let action = item.action, ReaderWindowController.instancesRespond(to: action) else { continue }
            #expect(!view.responds(to: action), "\(action)")
        }
    }

    @Test func searchFieldOffersTheOptions() throws {
        let harness = try NavigationHarness(FixturePDF.prose(pages: 1))
        defer { harness.close() }
        let toolbar = try #require(harness.controller.window?.toolbar)
        _ = harness.controller.toolbar(toolbar, itemForItemIdentifier: .search, willBeInsertedIntoToolbar: true)
        let field = try #require(harness.controller.searchField)
        let actions = field.searchMenuTemplate?.items.compactMap(\.action) ?? []
        #expect(actions.contains(#selector(ReaderWindowController.toggleMatchCase(_:))))
        #expect(actions.contains(#selector(ReaderWindowController.toggleWholeWord(_:))))

        field.stringValue = "prose"
        harness.controller.searchFieldChanged(field)
        #expect(harness.controller.isSearching)
        field.stringValue = ""
        harness.controller.searchFieldChanged(field)
        #expect(!harness.controller.isSearching)
    }
}

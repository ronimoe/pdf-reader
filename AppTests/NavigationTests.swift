import AppKit
import PDFKit
import Persistence
import ReaderCore
import ReaderKit
import ReaderUI
import Testing
@testable import Lectern

/// Drives a reader window in-process, without showing it. Documents come
/// from memory (nothing stored) or from a temporary file with a temporary
/// store.
@MainActor
struct NavigationHarness {
    let document: ReaderDocument
    let controller: ReaderWindowController
    let presenter = RecordingPresenter()

    init(_ data: Data, size: NSSize = NSSize(width: 800, height: 600)) throws {
        try self.init(document: ReaderDocument.loaded(data), store: nil, size: size)
    }

    init(file: URL, store: DocumentStateStore?, size: NSSize = NSSize(width: 800, height: 600)) throws {
        try self.init(document: ReaderDocument.opened(file), store: store, size: size)
    }

    private init(document: ReaderDocument, store: DocumentStateStore?, size: NSSize) throws {
        self.document = document
        controller = ReaderWindowController(document: document, passwordStore: InMemoryPasswordStore(), presenter: presenter, stateStore: store)
        document.addWindowController(controller)
        controller.window?.setContentSize(size)
        controller.splitViewController.view.layoutSubtreeIfNeeded()
    }

    var pdfView: ReaderPDFView { controller.pdfView }
    var pane: ReaderPane { controller.pane }
    var history: HistoryStack { controller.pane.history }

    func close() { document.close() }

    /// Moves the content the way a scroll wheel does: outside the view's own
    /// adjustments.
    func userScroll(by points: CGFloat) {
        pdfView.noteUserInput()
        let scrollView = pdfView.documentView!.enclosingScrollView!
        let clip = scrollView.contentView
        var origin = clip.bounds.origin
        origin.y += clip.isFlipped ? points : -points
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }

    /// Puts the reader somewhere in the middle of `page`, as if they had
    /// scrolled there, and returns that place.
    @discardableResult
    func read(at page: Int, y: CGFloat = 520) -> ReadingAnchor {
        pdfView.restore(ReadingAnchor(pageIndex: page, pointInPage: CGPoint(x: 0, y: y), scale: 1))
        userScroll(by: 37)
        return pdfView.visibleAnchor!
    }

    /// The page at the top-left of the visible area. (PDFView's own
    /// `currentPage` follows a moment later.)
    var currentPageIndex: Int? { pdfView.visibleAnchor?.pageIndex }

    /// The page of the current selection, such as the search result shown.
    var selectedPageIndex: Int? {
        pdfView.currentSelection?.pages.first.flatMap { pdfView.document?.index(for: $0) }
    }
}

/// Runs the main run loop until `condition` holds or `timeout` passes.
@MainActor
func spin(timeout: TimeInterval = 5, until condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}

/// Suspends until `condition` holds or `timeout` passes, so work queued on
/// the main queue and the main actor (tasks, delayed blocks) gets to run.
@MainActor
func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        try? await Task.sleep(for: .milliseconds(20))
    }
}

/// The reader's place survived: the anchor's page point is on screen, at the
/// top edge of the area below the toolbar (within `tolerance` view points),
/// unless the document can't scroll that far.
@MainActor
func expectKeptPlace(_ before: ReadingAnchor, in view: ReaderPDFView, tolerance: CGFloat = 3, sourceLocation: SourceLocation = #_sourceLocation) {
    guard let page = view.document?.page(at: before.pageIndex),
          let clip = view.documentView?.enclosingScrollView?.contentView, let documentFrame = view.documentView?.frame
    else {
        Issue.record("no document", sourceLocation: sourceLocation)
        return
    }
    let point = view.convert(before.pointInPage, from: page)
    let insets = view.safeAreaInsets
    let visible = NSRect(x: insets.left, y: insets.bottom, width: view.bounds.width - insets.left - insets.right, height: view.bounds.height - insets.top - insets.bottom)
    #expect(visible.insetBy(dx: -tolerance, dy: -tolerance).contains(point), "point \(point) outside \(visible)", sourceLocation: sourceLocation)
    let atLimit = clip.bounds.minY <= documentFrame.minY + 1 || clip.bounds.maxY >= documentFrame.maxY - 1
    let atTop = abs(point.y - visible.maxY) <= tolerance
    #expect(atTop || atLimit, "point \(point.y) vs top \(visible.maxY), anchor now \(String(describing: view.visibleAnchor))", sourceLocation: sourceLocation)
}

// MARK: Keeping your place (A3)

@MainActor
@Suite struct KeepingYourPlaceTests {
    @Test func zoomKeepsThePlace() throws {
        let harness = try NavigationHarness(FixturePDF.prose(pages: 20))
        defer { harness.close() }
        let place = harness.read(at: 7)
        harness.controller.increaseZoom(nil)
        harness.controller.increaseZoom(nil)
        expectKeptPlace(place, in: harness.pdfView)
        harness.controller.zoomToFitPage(nil)
        expectKeptPlace(place, in: harness.pdfView)
    }

    @Test func zoomWithoutTheAnchorLosesThePlace() throws {
        // The positive control: PDFKit's own scale change moves the point.
        let harness = try NavigationHarness(FixturePDF.prose(pages: 20))
        defer { harness.close() }
        let place = harness.read(at: 7)
        harness.pdfView.noteUserInput()
        harness.pdfView.scaleFactor *= 2.5
        let after = try #require(harness.pdfView.visibleAnchor)
        #expect(!after.isSamePlace(as: place, tolerance: 3))
    }

    @Test func resizeKeepsThePlace() throws {
        let harness = try NavigationHarness(FixturePDF.prose(pages: 20))
        defer { harness.close() }
        let place = harness.read(at: 9)
        harness.controller.window?.setContentSize(NSSize(width: 1200, height: 900))
        expectKeptPlace(place, in: harness.pdfView)
        // A live resize is many small steps; the place doesn't drift.
        for width in stride(from: 1200, to: 600, by: -40) {
            harness.controller.window?.setContentSize(NSSize(width: CGFloat(width), height: 700))
        }
        expectKeptPlace(place, in: harness.pdfView)
    }

    @Test func layoutChangesKeepThePlace() throws {
        let harness = try NavigationHarness(FixturePDF.prose(pages: 20))
        defer { harness.close() }
        let place = harness.read(at: 6)
        harness.controller.showTwoPages(nil)
        expectKeptPlace(place, in: harness.pdfView)
        harness.controller.scrollPageByPage(nil)
        expectKeptPlace(place, in: harness.pdfView)
        harness.controller.showSinglePage(nil)
        harness.controller.scrollContinuously(nil)
        expectKeptPlace(place, in: harness.pdfView)
    }

    @Test func layoutChangeWithoutTheAnchorLosesThePlace() throws {
        let harness = try NavigationHarness(FixturePDF.prose(pages: 20))
        defer { harness.close() }
        let place = harness.read(at: 6)
        harness.pdfView.noteUserInput()
        harness.pdfView.displayMode = .twoUpContinuous
        harness.pdfView.layoutDocumentView()
        let after = try #require(harness.pdfView.visibleAnchor)
        #expect(!after.isSamePlace(as: place, tolerance: 3))
    }

    @Test func rotationKeepsThePlace() throws {
        let harness = try NavigationHarness(FixturePDF.prose(pages: 20))
        defer { harness.close() }
        let place = harness.read(at: 5)
        harness.controller.rotateDocumentRight(nil)
        expectKeptPlace(place, in: harness.pdfView)
        harness.controller.rotateDocumentRight(nil)
        expectKeptPlace(place, in: harness.pdfView)
        harness.controller.rotateDocumentLeft(nil)
        harness.controller.rotateDocumentLeft(nil)
        expectKeptPlace(place, in: harness.pdfView)
    }

    @Test func reloadKeepsThePlace() throws {
        let harness = try NavigationHarness(FixturePDF.prose(pages: 20))
        defer { harness.close() }
        let place = harness.read(at: 11)
        var changed = FixturePDF.prose(pages: 21)
        changed.append(Data("% changed\n".utf8))
        harness.document.reload(with: changed, pdf: try #require(PDFDocument(data: changed)))
        #expect(harness.pdfView.document?.pageCount == 21)
        expectKeptPlace(place, in: harness.pdfView)
    }

    @Test func reloadWithFewerPagesClampsThePlace() throws {
        let harness = try NavigationHarness(FixturePDF.prose(pages: 20))
        defer { harness.close() }
        harness.read(at: 15)
        let shorter = FixturePDF.prose(pages: 4)
        harness.document.reload(with: shorter, pdf: try #require(PDFDocument(data: shorter)))
        #expect(harness.currentPageIndex == 3)
    }

    @Test func theAnchorIsBelowTheToolbar() throws {
        let harness = try NavigationHarness(FixturePDF.prose(pages: 5))
        defer { harness.close() }
        let anchor = ReadingAnchor(pageIndex: 2, pointInPage: CGPoint(x: 0, y: 500), scale: 1)
        harness.pdfView.restore(anchor)
        let page = try #require(harness.pdfView.document?.page(at: 2))
        let point = harness.pdfView.convert(anchor.pointInPage, from: page)
        let top = harness.pdfView.bounds.height - harness.pdfView.safeAreaInsets.top
        #expect(abs(point.y - top) < 2, "point \(point.y), safe-area top \(top)")
    }
}

// MARK: History (B2)

@MainActor
@Suite struct HistoryTests {
    @Test func outlineJumpsAddAnEntryAndBackReturns() throws {
        let harness = try NavigationHarness(FixturePDF.book())
        defer { harness.close() }
        let place = harness.read(at: 1, y: 300)
        let outline = harness.controller.outlineSection
        _ = outline.view
        let row = try #require((0..<outline.outlineView.numberOfRows).first {
            (outline.outlineView.item(atRow: $0) as? PDFOutline)?.label == "Chapter One"
        })
        outline.activate(row: row)
        #expect(harness.currentPageIndex == 2)
        #expect(harness.history.backList.count == 1)

        harness.controller.navigateBack(nil)
        expectKeptPlace(place, in: harness.pdfView)
        #expect(harness.pane.canGoForward)
        harness.controller.navigateForward(nil)
        #expect(harness.currentPageIndex == 2)
    }

    @Test func outlineDestinationsLandOnTheirPoint() throws {
        let harness = try NavigationHarness(FixturePDF.book())
        defer { harness.close() }
        let outline = harness.controller.outlineSection
        _ = outline.view
        outline.outlineView.expandItem(nil, expandChildren: true)
        let row = try #require((0..<outline.outlineView.numberOfRows).first {
            (outline.outlineView.item(atRow: $0) as? PDFOutline)?.label == "Section 1.1"
        })
        outline.activate(row: row)
        let anchor = try #require(harness.pdfView.visibleAnchor)
        #expect(anchor.pageIndex == 3)
        #expect(abs(anchor.pointInPage.y - 400) < 2)
    }

    @Test func thumbnailClicksAndReturnJumpButArrowKeysOnlySelect() throws {
        let harness = try NavigationHarness(FixturePDF.prose(pages: 10))
        defer { harness.close() }
        let table = harness.controller.thumbnailsSection.tableView
        #expect(table.numberOfRows == 10)
        table.selectRowIndexes(IndexSet(integer: 6), byExtendingSelection: false)
        #expect(harness.currentPageIndex == 0)
        #expect(harness.history.isEmpty)

        let returnKey = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        ))
        table.keyDown(with: returnKey)
        #expect(harness.currentPageIndex == 6)
        #expect(harness.history.backList.count == 1)
    }

    @Test func theCurrentPageIsHighlightedInTheThumbnails() throws {
        let harness = try NavigationHarness(FixturePDF.prose(pages: 10))
        defer { harness.close() }
        harness.pane.jump(toPageAt: 4)
        spin { harness.controller.thumbnailsSection.currentPage == 4 }
        #expect(harness.controller.thumbnailsSection.currentPage == 4)
    }

    @Test func scrollingNeverAddsAnEntry() throws {
        let harness = try NavigationHarness(FixturePDF.prose(pages: 10))
        defer { harness.close() }
        for _ in 0..<20 { harness.userScroll(by: 300) }
        #expect(harness.currentPageIndex ?? 0 > 2)
        #expect(harness.history.isEmpty)
        #expect(!harness.controller.validateMenuItem(NSMenuItem(title: "", action: #selector(ReaderWindowController.navigateBack(_:)), keyEquivalent: "")))
    }

    @Test func linksPDFKitFollowsAddAnEntry() throws {
        let harness = try NavigationHarness(FixturePDF.prose(pages: 10))
        defer { harness.close() }
        let place = harness.read(at: 1)
        let target = try #require(harness.pdfView.document?.page(at: 8))
        harness.pdfView.perform(PDFActionGoTo(destination: PDFDestination(page: target, at: CGPoint(x: 0, y: 700))))
        #expect(harness.currentPageIndex == 8)
        #expect(harness.history.backList.count == 1)
        harness.controller.navigateBack(nil)
        expectKeptPlace(place, in: harness.pdfView)
    }

    @Test func namedGoBackUsesThePanesHistory() throws {
        let harness = try NavigationHarness(FixturePDF.prose(pages: 10))
        defer { harness.close() }
        harness.pane.jump(toPageAt: 7)
        harness.pdfView.perform(PDFActionNamed(name: .goBack))
        #expect(harness.currentPageIndex == 0)
        harness.pdfView.perform(PDFActionNamed(name: .goForward))
        #expect(harness.currentPageIndex == 7)
    }

    @Test func historyIsPerPane() throws {
        let harness = try NavigationHarness(FixturePDF.prose(pages: 4))
        defer { harness.close() }
        #expect(harness.pane.id == .primary)
        let other = ReaderPane(id: .secondary)
        other.view.document = harness.pdfView.document
        other.jump(toPageAt: 3)
        #expect(other.history.backList.count == 1)
        #expect(harness.history.isEmpty)
    }
}

// MARK: Go to page

@MainActor
@Suite struct GoToPageTests {
    @Test func labelsAndNumbersBothWork() throws {
        let harness = try NavigationHarness(FixturePDF.book())
        defer { harness.close() }
        #expect(harness.document.pageNumbering.definesLabels)
        harness.controller.showGoToPage(nil)
        let prompt = try #require(harness.presenter.goToPagePrompts.last)
        #expect(prompt.input == "i")
        prompt.input = "ii"
        prompt.submit()
        #expect(harness.currentPageIndex == 1)
        #expect(harness.presenter.goToPageDismissals == 1)
        #expect(harness.history.backList.count == 1)

        harness.controller.showGoToPage(nil)
        let second = try #require(harness.presenter.goToPagePrompts.last)
        // "3" is the label of the fifth page.
        second.input = "3"
        second.submit()
        #expect(harness.currentPageIndex == 4)
        #expect(harness.history.backList.count == 2)
    }

    @Test func invalidInputIsExplainedAndTheSheetStays() throws {
        let harness = try NavigationHarness(FixturePDF.prose(pages: 5))
        defer { harness.close() }
        harness.controller.showGoToPage(nil)
        let prompt = try #require(harness.presenter.goToPagePrompts.last)
        prompt.input = "12"
        prompt.submit()
        #expect(prompt.errorMessage == "There’s no page “12”. Enter a page number from 1 to 5.")
        #expect(harness.presenter.goToPageDismissals == 0)
        #expect(harness.currentPageIndex == 0)
        #expect(harness.history.isEmpty)
        prompt.cancel()
        #expect(harness.presenter.goToPageDismissals == 1)
        #expect(harness.controller.goToPagePrompt == nil)
    }
}

// MARK: Sidebar (spec §4.1)

@MainActor
@Suite struct SidebarTests {
    @Test func togglesAndRemembersItsSection() throws {
        let harness = try NavigationHarness(FixturePDF.book())
        defer { harness.close() }
        #expect(!harness.controller.isSidebarVisible)
        harness.controller.toggleReaderSidebar(nil)
        #expect(harness.controller.isSidebarVisible)
        #expect(harness.controller.settings.sidebar.isVisible)
        let item = NSMenuItem(title: "", action: #selector(ReaderWindowController.toggleReaderSidebar(_:)), keyEquivalent: "")
        _ = harness.controller.validateMenuItem(item)
        #expect(item.title == "Hide Sidebar")

        harness.controller.showTableOfContents(nil)
        #expect(harness.controller.sidebar.visibleSection == .outline)
        #expect(harness.controller.settings.sidebar.section == .outline)
        harness.controller.toggleReaderSidebar(nil)
        #expect(!harness.controller.settings.sidebar.isVisible)
    }

    @Test func outlineShowsTheDocumentsEntries() throws {
        let harness = try NavigationHarness(FixturePDF.book())
        defer { harness.close() }
        let outline = harness.controller.outlineSection
        _ = outline.view
        #expect(outline.hasOutline)
        #expect(outline.emptyLabel.isHidden)
        #expect(outline.outlineView.numberOfRows >= 3)
        let chapter = try #require((0..<outline.outlineView.numberOfRows).compactMap { outline.outlineView.item(atRow: $0) as? PDFOutline }.first { $0.label == "Chapter One" })
        #expect(outline.outlineView.isExpandable(chapter))
        #expect(outline.outlineView.accessibilityLabel() == "Table of contents")
    }

    @Test func showingASectionPutsKeyboardFocusInIt() throws {
        let harness = try NavigationHarness(FixturePDF.book())
        defer { harness.close() }
        let window = try #require(harness.controller.window)
        harness.controller.showTableOfContents(nil)
        #expect(window.firstResponder === harness.controller.outlineSection.outlineView)
        harness.controller.showThumbnails(nil)
        #expect(window.firstResponder === harness.controller.thumbnailsSection.tableView)
    }

    @Test func aDocumentWithoutAnOutlineSaysSo() throws {
        let harness = try NavigationHarness(FixturePDF.prose(pages: 3))
        defer { harness.close() }
        let outline = harness.controller.outlineSection
        _ = outline.view
        #expect(!outline.hasOutline)
        #expect(!outline.emptyLabel.isHidden)
        #expect(outline.emptyLabel.stringValue == "This document has no table of contents.")
    }

    @Test func thePickerOffersEachSectionWithALabel() throws {
        let harness = try NavigationHarness(FixturePDF.prose(pages: 3))
        defer { harness.close() }
        let sidebar = harness.controller.sidebar
        _ = sidebar.view
        // Search results appear only while a search runs.
        #expect(sidebar.availableSections == [.thumbnails, .outline])
        #expect(sidebar.picker.segmentCount == 2)
        for segment in 0..<sidebar.picker.segmentCount {
            #expect(sidebar.picker.image(forSegment: segment)?.accessibilityDescription?.isEmpty == false)
        }
        #expect(sidebar.picker.accessibilityLabel() == "Sidebar section")
    }
}

// MARK: Thumbnails off the main thread (architecture §4.6)

@Suite struct PageRendererTests {
    @Test func drawsThumbnailsAtTheRequestedSizeAndCachesThem() async throws {
        let renderer = PageRenderer(data: FixturePDF.prose(pages: 3))
        let image = try #require(await renderer.thumbnail(pageIndex: 1, fitting: CGSize(width: 93, height: 120), scale: 2, rotation: 0))
        #expect(image.height == 240)
        #expect(abs(image.width - 186) <= 2)
        let again = await renderer.thumbnail(pageIndex: 1, fitting: CGSize(width: 93, height: 120), scale: 2, rotation: 0)
        #expect(again === image)
        #expect(await renderer.thumbnail(pageIndex: 9, fitting: CGSize(width: 93, height: 120), scale: 2, rotation: 0) == nil)
    }

    @Test func followsTheViewRotation() async throws {
        let renderer = PageRenderer(data: FixturePDF.prose(pages: 1))
        let landscape = try #require(await renderer.thumbnail(pageIndex: 0, fitting: CGSize(width: 120, height: 93), scale: 1, rotation: 90))
        #expect(landscape.width > landscape.height)
    }

    @Test func opensEncryptedDocumentsWithTheSessionPassword() async throws {
        let data = try #require(TestPDF.encrypted(user: "user", owner: "owner"))
        let locked = PageRenderer(data: data)
        #expect(await locked.thumbnail(pageIndex: 0, fitting: CGSize(width: 93, height: 120), scale: 1, rotation: 0) == nil)
        let unlocked = PageRenderer(data: data, password: "user")
        #expect(await unlocked.thumbnail(pageIndex: 0, fitting: CGSize(width: 93, height: 120), scale: 1, rotation: 0) != nil)
    }

    @Test func rendersInParallelWithTheMainThread() async throws {
        // The renderer's own document draws while the main thread is busy
        // with the on-screen one: the main actor never waits for it.
        let data = FixturePDF.prose(pages: 40)
        let renderer = PageRenderer(data: data)
        let rendering = Task.detached {
            var count = 0
            for index in 0..<40 where await renderer.thumbnail(pageIndex: index, fitting: CGSize(width: 93, height: 120), scale: 2, rotation: 0) != nil {
                count += 1
            }
            return count
        }
        let busy = await MainActor.run { () -> Int in
            let document = PDFDocument(data: data)!
            return (0..<40).reduce(0) { $0 + (document.page(at: $1)?.string?.count ?? 0) }
        }
        #expect(busy > 0)
        #expect(await rendering.value == 40)
    }
}

@Suite struct TextInventoryTests {
    @Test func findsPagesWithoutText() async {
        let data = FixturePDF.make(pageTexts: ["words", nil, "more words", nil])
        #expect(await TextInventory(data: data).pagesWithoutText() == [1, 3])
    }
}

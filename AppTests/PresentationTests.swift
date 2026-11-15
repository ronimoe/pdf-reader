import AppKit
import PDFKit
import Persistence
import ReaderCore
import ReaderKit
import ReaderUI
import Testing
@testable import Lectern

/// Presentation mode (View ▸ Start Presentation): the slides come from the reader's document,
/// the reader doesn't move until the presentation ends, and then moves to the last slide shown.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)), .noUI)
struct PresentationTests {
    // MARK: Starting and stopping

    @Test func theViewMenuStartsAndStopsItWithOptionCommandP() throws {
        let menuItem = try #require(allMenuItems(MainMenu.make()).first { $0.action == #selector(ReaderWindowController.togglePresentation(_:)) })
        #expect(menuItem.title == "Start Presentation")
        #expect(KeyboardShortcutCatalog.keys(for: menuItem) == "⌥⌘P")
        #expect(KeyboardShortcutCatalog.groups(from: MainMenu.make()).flatMap(\.entries).contains { $0.title == "Start Presentation" && $0.keys == "⌥⌘P" })

        let h = try PresentationHarness()
        defer { h.close() }
        let item = NSMenuItem(title: "", action: #selector(ReaderWindowController.togglePresentation(_:)), keyEquivalent: "")
        #expect(h.controller.validateMenuItem(item))
        #expect(item.title == "Start Presentation")
        h.controller.togglePresentation(nil)
        let presentation = try #require(h.presenter.current)
        #expect(h.controller.validateMenuItem(item))
        #expect(item.title == "Stop Presentation")
        // The slides' own window answers the same item while it is key.
        let fromSlides = NSMenuItem(title: "", action: #selector(PresentationController.togglePresentation(_:)), keyEquivalent: "")
        #expect(presentation.validateMenuItem(fromSlides))
        #expect(fromSlides.title == "Stop Presentation")
        presentation.togglePresentation(nil)
        #expect(h.presenter.current == nil)
        #expect(!h.controller.isPresenting)
        #expect(presentation.hasEnded)
    }

    @Test func itStartsOnTheFocusedPanesPageAndLeavesTheReaderAlone() throws {
        let h = try PresentationHarness()
        defer { h.close() }
        h.read(at: 3)
        let place = try snapshot(h.view)
        let settings = h.controller.settings
        let presentation = try h.start()
        #expect(presentation.currentIndex == 3)
        #expect(presentation.slideView.document === h.view.document, "the reader's own document")
        #expect(PresentationHarness.pointer.last == true, "the pointer hides")
        presentation.perform(.next)
        presentation.perform(.toggleBlack)
        presentation.perform(.first)
        expectUnmoved(place, in: h.view)
        #expect(h.controller.settings == settings)
        #expect(h.pane.history.isEmpty)
    }

    @Test func aDocumentThatIsntShowingCantBePresented() throws {
        let locked = try #require(TestPDF.encrypted(user: "user", owner: "owner"))
        let h = try PresentationHarness(locked)
        defer { h.close() }
        let item = NSMenuItem(title: "", action: #selector(ReaderWindowController.togglePresentation(_:)), keyEquivalent: "")
        #expect(!h.controller.validateMenuItem(item))
        h.controller.startPresentation()
        #expect(h.presenter.current == nil)
    }

    @Test func thereIsOnePresentationAtATime() throws {
        let presenter = TestPresentationPresenter()
        let a = try PresentationHarness(presenter: presenter)
        defer { a.close() }
        let b = try PresentationHarness(presenter: presenter)
        defer { b.close() }
        let first = try a.start()
        _ = try b.start()
        #expect(first.hasEnded)
        #expect(!a.controller.isPresenting)
        #expect(b.controller.isPresenting)
    }

    // MARK: Keys

    @Test func keysWorkAsInPresentationSoftware() throws {
        let h = try PresentationHarness()
        defer { h.close() }
        h.read(at: 0)
        let p = try h.start()
        func press(_ code: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags = []) {
            p.keyDown(with: Keys.event(code, characters, modifiers))
        }
        press(124, Keys.right)
        #expect(p.currentIndex == 1)
        press(49, " ")
        #expect(p.currentIndex == 2)
        press(125, Keys.down)
        #expect(p.currentIndex == 3)
        press(121, Keys.pageDown)
        #expect(p.currentIndex == 4)
        press(123, Keys.left)
        #expect(p.currentIndex == 3)
        press(49, " ", .shift)
        #expect(p.currentIndex == 2)
        press(116, Keys.pageUp)
        #expect(p.currentIndex == 1)
        press(51, "\u{7f}")
        #expect(p.currentIndex == 0)
        press(119, Keys.end)
        #expect(p.currentIndex == 5)
        press(115, Keys.home)
        #expect(p.currentIndex == 0)
        press(45, "n")
        #expect(p.currentIndex == 1)
        press(35, "p")
        #expect(p.currentIndex == 0)

        // A slide number, then Return.
        press(21, "4")
        #expect(p.notice.message == "Go to slide 4")
        #expect(p.currentIndex == 0)
        press(36, "\r")
        #expect(p.currentIndex == 3)
        #expect(p.notice.message == nil)
        #expect(p.slideView.accessibilityLabel() == "Slide 4 of 6")
        press(25, "9")
        press(25, "9")
        press(76, "\u{3}")
        #expect(p.notice.message == "There’s no slide 99.")
        #expect(p.currentIndex == 3)

        // Blanking: the first move only brings the slide back.
        press(11, "b")
        #expect(p.slideView.blank == .black)
        #expect(p.slideView.accessibilityLabel() == "Black screen")
        press(124, Keys.right)
        #expect(p.slideView.blank == nil)
        #expect(p.currentIndex == 3)
        press(13, "w")
        #expect(p.slideView.blank == .white)
        press(47, ".")
        #expect(p.slideView.blank == .black)
        press(43, ",")
        #expect(p.slideView.blank == .white)
        press(13, "w")
        #expect(p.slideView.blank == nil)

        // Keys with ⌘, ⌥ or ⌃ are the menus'; other keys do nothing.
        press(124, Keys.right, .command)
        press(124, Keys.right, .option)
        press(15, "r")
        #expect(p.currentIndex == 3)

        press(53, "\u{1b}")
        #expect(p.hasEnded)
        #expect(h.presenter.current == nil)
        #expect(!h.controller.isPresenting)
        #expect(PresentationHarness.pointer.last == false, "the pointer is back")
    }

    @Test func escapeFirstClearsATypedNumber() throws {
        let h = try PresentationHarness()
        defer { h.close() }
        let p = try h.start()
        p.keyDown(with: Keys.event(20, "3"))
        p.keyDown(with: Keys.event(53, "\u{1b}"))
        #expect(!p.hasEnded)
        #expect(p.notice.message == nil)
        p.cancelOperation(nil)
        #expect(p.hasEnded, "⌘. ends it")
    }

    // MARK: Ending

    @Test func endingTakesTheReaderToTheLastSlideAndBackReturns() throws {
        let h = try PresentationHarness()
        defer { h.close() }
        let before = h.read(at: 1)
        let p = try h.start()
        p.perform(.next)
        p.perform(.next)
        p.end()
        #expect(p.hasEnded)
        #expect(h.view.currentAnchor?.pageIndex == 3)
        #expect(h.view.pageIndexInMiddle == 3)
        #expect(h.pane.canGoBack)
        h.controller.navigateBack(nil)
        #expect(h.view.currentAnchor?.isSamePlace(as: before, tolerance: 1) == true)
    }

    @Test func endingOnTheSlideItStartedOnMovesNothing() throws {
        let h = try PresentationHarness()
        defer { h.close() }
        h.read(at: 2)
        let place = try snapshot(h.view)
        let p = try h.start()
        p.perform(.next)
        p.perform(.previous)
        p.end()
        expectUnmoved(place, in: h.view)
        #expect(h.pane.history.isEmpty)
    }

    @Test func closingTheWindowEndsItWithoutMovingTheReader() throws {
        let h = try PresentationHarness()
        defer { h.close() }
        h.read(at: 0)
        let p = try h.start()
        p.perform(.last)
        h.controller.close()
        #expect(p.hasEnded)
        #expect(h.presenter.current == nil)
        #expect(!h.controller.isPresenting)
        #expect(h.pane.history.isEmpty)
    }

    @Test func aSheetOnTheReaderWindowEndsItSoTheSheetIsSeen() throws {
        let h = try PresentationHarness()
        defer { h.close() }
        h.read(at: 0)
        let p = try h.start()
        p.perform(.next)
        // The window's delegate hears this as a sheet begins: a question, an error, the review
        // of unsaved changes at quit.
        #expect(h.controller.responds(to: #selector(NSWindowDelegate.windowWillBeginSheet(_:))))
        h.controller.windowWillBeginSheet(Notification(name: NSWindow.willBeginSheetNotification, object: h.controller.window))
        #expect(p.hasEnded)
        #expect(!h.controller.isPresenting)
        #expect(h.view.currentAnchor?.pageIndex == 1, "an ordinary end: the reader shows the last slide")
    }

    @Test func aDeckReexportedDuringTheTalkKeepsTheSlide() throws {
        let h = try PresentationHarness()
        defer { h.close() }
        h.read(at: 0)
        let p = try h.start()
        p.perform(.next)
        let shorter = PresentationDeck.make(pages: 3)
        let pdf = try #require(PDFDocument(data: shorter))
        h.document.reload(with: shorter, pdf: pdf)
        #expect(h.presenter.current === p, "still presenting")
        #expect(p.slideView.document === pdf)
        #expect(p.currentIndex == 1)
        p.perform(.last)
        #expect(p.currentIndex == 2)
    }

    // MARK: Links

    @Test func clicksFollowLinksOnASlideOrGoToTheNextOne() throws {
        let h = try PresentationHarness()
        defer { h.close() }
        h.read(at: 1)
        let p = try h.start()
        let slide = p.slideView
        func center(of pageRect: CGRect) throws -> CGPoint {
            let rect = try #require(slide.layout).viewRect(forPageRect: pageRect)
            return CGPoint(x: rect.midX, y: rect.midY)
        }
        func click(_ pageRect: CGRect) throws {
            let point = try center(of: pageRect)
            slide.handleClick(pressedOn: slide.link(at: point)?.annotation, releasedAt: point)
        }

        // A web link opens in the browser, as from the page; the slide stays.
        try click(PresentationDeck.web)
        #expect(h.opener.opened.map(\.absoluteString) == ["https://lectern-probe.invalid/slides"])
        #expect(p.currentIndex == 1)
        // A blocked link is explained on the slide: no sheet behind it.
        try click(PresentationDeck.script)
        #expect(p.notice.message == "This link would run a script.")
        #expect(p.currentIndex == 1)
        // A link inside the document moves the presentation.
        try click(PresentationDeck.jump)
        #expect(p.currentIndex == 4)
        // Anywhere else, the next slide.
        slide.handleClick(pressedOn: nil, releasedAt: CGPoint(x: 2, y: 2))
        #expect(p.currentIndex == 5)

        p.perform(.first)
        p.perform(.next)
        try click(PresentationDeck.lastPage)
        #expect(p.currentIndex == 5, "a LastPage action")
        // A press that starts on a link and ends off it does nothing.
        p.perform(.first)
        p.perform(.next)
        let jump = slide.link(at: try center(of: PresentationDeck.jump))?.annotation
        #expect(jump != nil)
        slide.handleClick(pressedOn: jump, releasedAt: CGPoint(x: 2, y: 2))
        #expect(p.currentIndex == 1)
        // The reader never moved.
        #expect(h.pane.history.isEmpty)
    }

    // MARK: Drawing

    @Test func theSlideIsFittedOnBlackAndTurnsWithTheReader() throws {
        let h = try PresentationHarness()
        defer { h.close() }
        h.read(at: 0)
        let p = try h.start()
        let slide = p.slideView
        // 4:3 on 16:9 (1280 by 720): 960 by 720, with bars 160 wide.
        #expect(slide.layout?.frame == CGRect(x: 160, y: 0, width: 960, height: 720))
        var image = try Pixels(of: slide)
        #expect(image.isBlack(at: CGPoint(x: 80, y: 360)), "the bar")
        #expect(image.isRed(at: CGPoint(x: 200, y: 680)), "the page's top-left corner")
        #expect(image.isWhite(at: CGPoint(x: 1000, y: 200)))

        // The reader's view rotation shows on the slides: the corner turns to the top right.
        h.controller.rotateDocumentRight(nil)
        image = try Pixels(of: slide)
        #expect(slide.layout?.frame == CGRect(x: 370, y: 0, width: 540, height: 720))
        #expect(image.isRed(at: CGPoint(x: 850, y: 680)))
        #expect(image.isBlack(at: CGPoint(x: 200, y: 680)))

        p.perform(.toggleBlack)
        image = try Pixels(of: slide)
        #expect(image.isBlack(at: CGPoint(x: 640, y: 360)))
        p.perform(.toggleWhite)
        image = try Pixels(of: slide)
        #expect(image.isWhite(at: CGPoint(x: 80, y: 360)))
    }

    @Test func unsavedAnnotationsShowOnTheSlides() throws {
        let h = try PresentationHarness()
        defer { h.close() }
        h.read(at: 0)
        let p = try h.start()
        let page = try #require(h.view.document?.page(at: 0))
        let highlight = PDFAnnotation(bounds: CGRect(x: 300, y: 150, width: 80, height: 40), forType: .highlight, withProperties: nil)
        highlight.color = .blue
        page.addAnnotation(highlight)
        defer { page.removeAnnotation(highlight) }
        p.refresh()
        let image = try Pixels(of: p.slideView)
        // Page (340, 170) is at view (160 + 340 × 2.4, 170 × 2.4).
        #expect(image.isBlue(at: CGPoint(x: 976, y: 408)))
    }

    // MARK: The suggestion

    @Test func aSlideDeckSuggestsPresentingOnce() throws {
        let preferences = ReaderPreferences.ephemeral()
        let first = try PresentationHarness(preferences: preferences)
        defer { first.close() }
        #expect(first.controller.notice.message?.contains("View ▸ Start Presentation (⌥⌘P)") == true)
        #expect(preferences.hasSeenPresentationSuggestion)
        #expect(first.presenter.current == nil, "only a suggestion")
        let second = try PresentationHarness(preferences: preferences)
        defer { second.close() }
        #expect(second.controller.notice.message == nil)
    }

    @Test func otherDocumentsDontSuggestItAndPresentingCountsAsSeen() throws {
        let preferences = ReaderPreferences.ephemeral()
        let book = try PresentationHarness(try #require(TestPDF.make(pageCount: 4)), preferences: preferences)
        defer { book.close() }
        #expect(book.controller.notice.message == nil)
        #expect(!preferences.hasSeenPresentationSuggestion)
        _ = try book.start()
        #expect(preferences.hasSeenPresentationSuggestion)
        let deck = try PresentationHarness(preferences: preferences)
        defer { deck.close() }
        #expect(deck.controller.notice.message == nil)
    }

    // MARK: The window

    @Test func theSlidesWindowIsNeverATabRestoredOrListed() {
        let window = PresentationWindow(covering: NSRect(x: 0, y: 0, width: 640, height: 480))
        defer { window.close() }
        #expect(window.styleMask == [.borderless])
        #expect(window.tabbingMode == .disallowed)
        #expect(!window.isRestorable)
        #expect(window.isExcludedFromWindowsMenu)
        #expect(window.canBecomeKey)
        var closed = false
        window.onClose = { closed = true }
        let close = NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        #expect(window.validateMenuItem(close), "⌘W ends the presentation")
        window.performClose(nil)
        #expect(closed)
    }
}

// MARK: Support

/// Six 4:3 slides (400 by 300) with a red square in each top-left corner and "Slide n" in the
/// middle. Slide 2 has links: to slide 5, to a web page, to a script, and a LastPage action.
nonisolated enum PresentationDeck {
    static let jump = CGRect(x: 20, y: 20, width: 100, height: 40)
    static let web = CGRect(x: 140, y: 20, width: 100, height: 40)
    static let script = CGRect(x: 260, y: 20, width: 120, height: 40)
    static let lastPage = CGRect(x: 140, y: 80, width: 100, height: 30)

    static func make(pages count: Int = 6) -> Data {
        var objects: [Int: String] = [:]
        objects[1] = "<< /Type /Catalog /Pages 2 0 R >>"
        objects[2] = "<< /Type /Pages /Kids [\((0..<count).map { "\(3 + $0) 0 R" }.joined(separator: " "))] /Count \(count) >>"
        objects[19] = SpikeRawPDF.helvetica
        for index in 0..<count {
            let annots = index == 1 && count > 4 ? " /Annots [50 0 R 51 0 R 52 0 R 53 0 R]" : ""
            objects[3 + index] = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 300] /Contents \(20 + index) 0 R /Resources << /Font << /F1 19 0 R >> >>\(annots) >>"
            objects[20 + index] = SpikeRawPDF.stream("1 0 0 rg 0 240 60 60 re f\n0 g BT /F1 36 Tf 130 140 Td (Slide \(index + 1)) Tj ET\n")
        }
        func link(_ rect: CGRect, _ entry: String) -> String {
            "<< /Type /Annot /Subtype /Link /Rect [\(Int(rect.minX)) \(Int(rect.minY)) \(Int(rect.maxX)) \(Int(rect.maxY))] /Border [0 0 0] \(entry) >>"
        }
        if count > 4 {
            objects[50] = link(jump, "/A << /S /GoTo /D [7 0 R /Fit] >>")
            objects[51] = link(web, "/A << /S /URI /URI (https://lectern-probe.invalid/slides) >>")
            objects[52] = link(script, "/A << /S /JavaScript /JS (var lecternProbe = 1;) >>")
            objects[53] = link(lastPage, "/A << /S /Named /N /LastPage >>")
        }
        return SpikeRawPDF.build(objects: objects, root: 1).data
    }
}

/// Hosts presentations in an invisible 1280 by 720 window, as the link previews' test presenter
/// does, and records them.
@MainActor
final class TestPresentationPresenter: PresentationPresenting {
    private(set) var presented: [PresentationController] = []
    private var host: OffscreenHost?
    var current: PresentationController? { host == nil ? nil : presented.last }

    func present(_ controller: PresentationController, on screen: NSScreen?) {
        if let current { dismiss(current) }
        presented.append(controller)
        host = OffscreenHost(content: controller.view, size: NSSize(width: 1280, height: 720))
        controller.view.layoutSubtreeIfNeeded()
        controller.didBegin()
    }

    func dismiss(_ controller: PresentationController) {
        guard controller === current else { return }
        host?.close()
        host = nil
        controller.didEnd()
    }
}

/// A reader window on the deck, invisible, with presentations hosted offscreen and every way
/// out of the app recorded.
@MainActor
final class PresentationHarness {
    /// Every request to hide (true) or show (false) the pointer, instead of the real pointer.
    static var pointer: [Bool] = []

    let presenter: TestPresentationPresenter
    let opener = RecordingURLOpener()
    let preferences: ReaderPreferences
    let document: ReaderDocument
    let controller: ReaderWindowController
    private let blockedUIBefore = UITripwire.shared.calls.count

    init(
        _ data: Data = PresentationDeck.make(),
        presenter: TestPresentationPresenter = TestPresentationPresenter(),
        preferences: ReaderPreferences = .ephemeral()
    ) throws {
        PresentationController.setPointerHidden = { PresentationHarness.pointer.append($0) }
        self.presenter = presenter
        self.preferences = preferences
        document = try ReaderDocument.loaded(data)
        controller = ReaderWindowController(
            document: document, passwordStore: InMemoryPasswordStore(), presenter: RecordingPresenter(), stateStore: nil,
            previewPresenter: nil, urlOpener: opener, preferences: preferences, journal: nil,
            presentationPresenter: presenter
        )
        document.addWindowController(controller)
        M5Harness.makeInvisible(try #require(controller.window), size: NSSize(width: 800, height: 700))
        controller.splitViewController.view.layoutSubtreeIfNeeded()
        spin(timeout: 0.05) { false }
    }

    var view: ReaderPDFView { controller.pdfView }
    var pane: ReaderPane { controller.pane }

    /// Starts a presentation from the menu command.
    func start() throws -> PresentationController {
        controller.togglePresentation(nil)
        return try #require(presenter.current)
    }

    /// Puts the reader at the top of `page`, as if they had scrolled there.
    @discardableResult
    func read(at page: Int) -> ReadingAnchor {
        view.restore(ReadingAnchor(pageIndex: page, pointInPage: CGPoint(x: 0, y: 300), scale: 1))
        return view.currentAnchor!
    }

    func close() {
        let blocked = UITripwire.shared.calls.dropFirst(blockedUIBefore)
        #expect(blocked.isEmpty, "a test tried to show UI: \(Array(blocked))")
        if let current = presenter.current { presenter.dismiss(current) }
        controller.window?.orderOut(nil)
        document.close()
    }
}

/// Key-down events as the keyboard sends them.
@MainActor
enum Keys {
    static let right = String(UnicodeScalar(UInt16(NSRightArrowFunctionKey))!)
    static let left = String(UnicodeScalar(UInt16(NSLeftArrowFunctionKey))!)
    static let down = String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!)
    static let pageDown = String(UnicodeScalar(UInt16(NSPageDownFunctionKey))!)
    static let pageUp = String(UnicodeScalar(UInt16(NSPageUpFunctionKey))!)
    static let home = String(UnicodeScalar(UInt16(NSHomeFunctionKey))!)
    static let end = String(UnicodeScalar(UInt16(NSEndFunctionKey))!)

    static func event(_ code: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
        )!
    }
}

/// A view drawn into a bitmap, read at points in the view's own coordinates (y up).
@MainActor
struct Pixels {
    let rep: NSBitmapImageRep
    let size: CGSize

    init(of view: NSView) throws {
        view.layoutSubtreeIfNeeded()
        rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        size = view.bounds.size
    }

    func colour(at point: CGPoint) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        let x = Int(point.x * CGFloat(rep.pixelsWide) / size.width)
        let y = Int((size.height - point.y) * CGFloat(rep.pixelsHigh) / size.height)
        let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) ?? .clear
        return (colour.redComponent, colour.greenComponent, colour.blueComponent)
    }

    func isBlack(at point: CGPoint) -> Bool { let c = colour(at: point); return c.red < 0.1 && c.green < 0.1 && c.blue < 0.1 }
    func isWhite(at point: CGPoint) -> Bool { let c = colour(at: point); return c.red > 0.9 && c.green > 0.9 && c.blue > 0.9 }
    func isRed(at point: CGPoint) -> Bool { let c = colour(at: point); return c.red > 0.8 && c.green < 0.3 && c.blue < 0.3 }
    func isBlue(at point: CGPoint) -> Bool { let c = colour(at: point); return c.blue > 0.6 && c.red < 0.6 }
}

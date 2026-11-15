import CoreGraphics
import Foundation
import Testing
@testable import ReaderCore

/// Presentation mode's pure parts: what each key does, where a slide goes on the screen, and
/// which documents look like slides.
@Suite struct SlideNavigatorTests {
    let plain = PageNumbering(pageCount: 5)

    @Test func startsWhereAskedWithinTheDocument() {
        #expect(SlideNavigator(pageCount: 5, startingAt: 2).index == 2)
        #expect(SlideNavigator(pageCount: 5, startingAt: 9).index == 4)
        #expect(SlideNavigator(pageCount: 5, startingAt: -1).index == 0)
        #expect(SlideNavigator(pageCount: 0, startingAt: 3).index == 0)
    }

    @Test func nextAndPreviousStopAtEitherEndWithoutWrapping() {
        var nav = SlideNavigator(pageCount: 3, startingAt: 0)
        #expect(nav.perform(.previous, numbering: plain) == .unchanged)
        #expect(nav.perform(.next, numbering: plain) == .changed)
        #expect(nav.perform(.next, numbering: plain) == .changed)
        #expect(nav.index == 2)
        #expect(nav.perform(.next, numbering: plain) == .unchanged)
        #expect(nav.index == 2)
        #expect(nav.perform(.first, numbering: plain) == .changed)
        #expect(nav.index == 0)
        #expect(nav.perform(.last, numbering: plain) == .changed)
        #expect(nav.index == 2)
    }

    @Test func returnWithNothingTypedIsTheNextSlide() {
        var nav = SlideNavigator(pageCount: 3, startingAt: 0)
        #expect(nav.perform(.confirm, numbering: plain) == .changed)
        #expect(nav.index == 1)
    }

    @Test func aTypedNumberAndReturnGoToThatSlide() {
        var nav = SlideNavigator(pageCount: 5, startingAt: 0)
        #expect(nav.perform(.digit(4), numbering: plain) == .changed)
        #expect(nav.typed == "4")
        #expect(nav.index == 0, "nothing moves until Return")
        #expect(nav.perform(.confirm, numbering: plain) == .changed)
        #expect(nav.index == 3)
        #expect(nav.typed.isEmpty)
    }

    @Test(arguments: [[0], [9], [9, 9]])
    func aNumberThatNamesNoSlideIsReportedAndCleared(digits: [Int]) {
        var nav = SlideNavigator(pageCount: 5, startingAt: 2)
        for digit in digits { _ = nav.perform(.digit(digit), numbering: plain) }
        let typed = digits.map(String.init).joined()
        #expect(nav.perform(.confirm, numbering: plain) == .noSuchSlide(typed))
        #expect(nav.index == 2)
        #expect(nav.typed.isEmpty)
    }

    @Test func typedNumbersMatchTheDocumentsOwnLabelsFirst() {
        // Beamer labels every overlay of a frame with the frame's number.
        let beamer = PageNumbering(labels: ["1", "2", "2", "2", "3"], definesLabels: true)
        var nav = SlideNavigator(pageCount: 5, startingAt: 0)
        _ = nav.perform(.digit(3), numbering: beamer)
        _ = nav.perform(.confirm, numbering: beamer)
        #expect(nav.index == 4, "frame 3 is the fifth page")
        _ = nav.perform(.digit(2), numbering: beamer)
        _ = nav.perform(.confirm, numbering: beamer)
        #expect(nav.index == 1, "frame 2 starts at its first overlay")
    }

    @Test func deleteRemovesATypedDigitOrGoesBack() {
        var nav = SlideNavigator(pageCount: 20, startingAt: 5)
        _ = nav.perform(.digit(1), numbering: PageNumbering(pageCount: 20))
        _ = nav.perform(.digit(2), numbering: PageNumbering(pageCount: 20))
        #expect(nav.perform(.deleteBackward, numbering: PageNumbering(pageCount: 20)) == .changed)
        #expect(nav.typed == "1")
        #expect(nav.index == 5)
        _ = nav.perform(.deleteBackward, numbering: PageNumbering(pageCount: 20))
        #expect(nav.typed.isEmpty)
        _ = nav.perform(.deleteBackward, numbering: PageNumbering(pageCount: 20))
        #expect(nav.index == 4)
    }

    @Test func escapeClearsATypedNumberFirstThenEnds() {
        var nav = SlideNavigator(pageCount: 5, startingAt: 1)
        _ = nav.perform(.digit(3), numbering: plain)
        #expect(nav.perform(.cancel, numbering: plain) == .changed)
        #expect(nav.typed.isEmpty)
        #expect(nav.index == 1)
        #expect(nav.perform(.cancel, numbering: plain) == .end)
    }

    @Test func movingDropsAHalfTypedNumber() {
        var nav = SlideNavigator(pageCount: 5, startingAt: 1)
        _ = nav.perform(.digit(4), numbering: plain)
        _ = nav.perform(.next, numbering: plain)
        #expect(nav.typed.isEmpty)
        #expect(nav.index == 2)
        // Even when the move goes nowhere, the typed number goes.
        var last = SlideNavigator(pageCount: 5, startingAt: 4)
        _ = last.perform(.digit(1), numbering: plain)
        #expect(last.perform(.next, numbering: plain) == .changed)
        #expect(last.typed.isEmpty)
    }

    @Test func typedNumbersAreCappedInLength() {
        var nav = SlideNavigator(pageCount: 5, startingAt: 0)
        for _ in 0..<SlideNavigator.maximumTypedDigits { _ = nav.perform(.digit(1), numbering: plain) }
        #expect(nav.perform(.digit(1), numbering: plain) == .unchanged)
        #expect(nav.typed.count == SlideNavigator.maximumTypedDigits)
    }

    @Test func blankingTogglesAndSwitchesBetweenBlackAndWhite() {
        var nav = SlideNavigator(pageCount: 5, startingAt: 2)
        _ = nav.perform(.toggleBlack, numbering: plain)
        #expect(nav.blank == .black)
        _ = nav.perform(.toggleWhite, numbering: plain)
        #expect(nav.blank == .white)
        _ = nav.perform(.toggleWhite, numbering: plain)
        #expect(nav.blank == nil)
        #expect(nav.index == 2)
    }

    @Test(arguments: [SlideNavigator.Command.next, .previous, .first, .last, .deleteBackward, .confirm])
    func theFirstMoveOnABlankScreenOnlyBringsTheSlideBack(command: SlideNavigator.Command) {
        var nav = SlideNavigator(pageCount: 5, startingAt: 2)
        _ = nav.perform(.toggleBlack, numbering: plain)
        #expect(nav.perform(command, numbering: plain) == .changed)
        #expect(nav.blank == nil)
        #expect(nav.index == 2)
    }

    @Test func aTypedSlideNumberShowsThroughABlankScreen() {
        var nav = SlideNavigator(pageCount: 5, startingAt: 0)
        _ = nav.perform(.toggleBlack, numbering: plain)
        _ = nav.perform(.digit(3), numbering: plain)
        _ = nav.perform(.confirm, numbering: plain)
        #expect(nav.blank == nil)
        #expect(nav.index == 2)
    }

    @Test func linksMoveThePresentationAndGoBackReturns() {
        var nav = SlideNavigator(pageCount: 10, startingAt: 2)
        #expect(nav.follow(to: 8) == .changed)
        #expect(nav.index == 8)
        _ = nav.follow(to: 9)
        #expect(nav.goBack() == .changed)
        #expect(nav.index == 8)
        _ = nav.goBack()
        #expect(nav.index == 2)
        #expect(nav.goBack() == .unchanged)
        // A link to the slide showing records nothing.
        _ = nav.follow(to: 2)
        #expect(nav.linkHistory.isEmpty)
    }

    @Test func aReloadKeepsTheSlideWhereItStillExists() {
        var nav = SlideNavigator(pageCount: 10, startingAt: 7)
        _ = nav.follow(to: 9)
        nav.setPageCount(12)
        #expect(nav.index == 9)
        nav.setPageCount(5)
        #expect(nav.index == 4)
        #expect(nav.pageCount == 5)
        #expect(nav.linkHistory == [4])
    }
}

@Suite struct SlideLayoutTests {
    /// 4:3, like Beamer's default frame.
    let slide = CGRect(x: 0, y: 0, width: 400, height: 300)

    @Test func aSlideIsFittedAndCentredWithBarsAtTheSides() {
        let layout = SlideLayout(pageBox: slide, rotation: 0, fitting: CGRect(x: 0, y: 0, width: 1600, height: 900))
        #expect(layout.scale == 3)
        #expect(layout.frame == CGRect(x: 200, y: 0, width: 1200, height: 900))
    }

    @Test func aTallerScreenGetsBarsAboveAndBelow() {
        let layout = SlideLayout(pageBox: slide, rotation: 0, fitting: CGRect(x: 0, y: 0, width: 800, height: 800))
        #expect(layout.scale == 2)
        #expect(layout.frame == CGRect(x: 0, y: 100, width: 800, height: 600))
    }

    @Test func aRotatedPageFitsByItsTurnedSize() {
        let layout = SlideLayout(pageBox: slide, rotation: 90, fitting: CGRect(x: 0, y: 0, width: 1600, height: 900))
        #expect(layout.scale == 2.25)
        #expect(layout.frame.size == CGSize(width: 675, height: 900))
    }

    /// Where the page's top-left and bottom-right corners appear for each rotation, as
    /// `PDFPage.draw(with:to:)` was measured to draw them (macOS 27): the page turns clockwise.
    @Test(arguments: [
        (0, "top-left", "bottom-right"),
        (90, "top-right", "bottom-left"),
        (180, "bottom-right", "top-left"),
        (270, "bottom-left", "top-right"),
    ])
    func cornersTurnClockwise(_ expected: (rotation: Int, topLeft: String, bottomRight: String)) {
        let (rotation, topLeftGoesTo, bottomRightGoesTo) = expected
        let box = CGRect(x: 100, y: 50, width: 400, height: 300)
        let layout = SlideLayout(pageBox: box, rotation: rotation, fitting: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        let frame = layout.frame
        func corner(_ name: String) -> CGPoint {
            switch name {
            case "top-left": CGPoint(x: frame.minX, y: frame.maxY)
            case "top-right": CGPoint(x: frame.maxX, y: frame.maxY)
            case "bottom-left": CGPoint(x: frame.minX, y: frame.minY)
            default: CGPoint(x: frame.maxX, y: frame.minY)
            }
        }
        func near(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) < 0.001 && abs(a.y - b.y) < 0.001 }
        #expect(near(layout.viewPoint(forPagePoint: CGPoint(x: box.minX, y: box.maxY)), corner(topLeftGoesTo)))
        #expect(near(layout.viewPoint(forPagePoint: CGPoint(x: box.maxX, y: box.minY)), corner(bottomRightGoesTo)))
    }

    @Test(arguments: [0, 90, 180, 270])
    func viewAndPagePointsRoundTrip(rotation: Int) {
        let box = CGRect(x: 36, y: 18, width: 400, height: 300)
        let layout = SlideLayout(pageBox: box, rotation: rotation, fitting: CGRect(x: 0, y: 0, width: 1440, height: 900))
        for point in [CGPoint(x: 36, y: 18), CGPoint(x: 100, y: 250), CGPoint(x: 436, y: 318), CGPoint(x: 300, y: 40)] {
            let back = layout.pagePoint(forViewPoint: layout.viewPoint(forPagePoint: point))
            #expect(abs(back.x - point.x) < 0.001 && abs(back.y - point.y) < 0.001)
        }
    }

    @Test func aPageRectangleMapsToTheViewRectangleItCovers() {
        let layout = SlideLayout(pageBox: slide, rotation: 90, fitting: CGRect(x: 0, y: 0, width: 300, height: 400))
        // The page's left strip becomes the turned page's top strip.
        let rect = layout.viewRect(forPageRect: CGRect(x: 0, y: 0, width: 40, height: 300))
        #expect(rect == CGRect(x: 0, y: 360, width: 300, height: 40))
    }

    @Test func nothingIsDrawnWithoutRoom() {
        #expect(SlideLayout(pageBox: slide, rotation: 0, fitting: .zero).frame == .zero)
        #expect(SlideLayout(pageBox: .zero, rotation: 0, fitting: CGRect(x: 0, y: 0, width: 10, height: 10)).scale == 0)
    }
}

@Suite struct SlideDeckHintsTests {
    let fourThree = CGSize(width: 362.83, height: 272.13)
    let sixteenNine = CGSize(width: 1920, height: 1080)
    let letter = CGSize(width: 612, height: 792)

    @Test func pagesOfOneLandscapeSlideSizeLookLikeSlides() {
        #expect(SlideDeckHints.looksLikeSlides(pageSizes: Array(repeating: fourThree, count: 12), opensInFullScreen: false, creator: nil))
        #expect(SlideDeckHints.looksLikeSlides(pageSizes: Array(repeating: sixteenNine, count: 3), opensInFullScreen: false, creator: nil))
    }

    @Test func portraitMixedFewOrOddlyShapedPagesDont() {
        #expect(!SlideDeckHints.looksLikeSlides(pageSizes: [], opensInFullScreen: false, creator: nil))
        #expect(!SlideDeckHints.looksLikeSlides(pageSizes: Array(repeating: letter, count: 30), opensInFullScreen: false, creator: nil))
        #expect(!SlideDeckHints.looksLikeSlides(pageSizes: [fourThree, fourThree], opensInFullScreen: false, creator: nil), "two pages could be a figure")
        #expect(!SlideDeckHints.looksLikeSlides(pageSizes: [fourThree, letter, fourThree], opensInFullScreen: false, creator: nil))
        let banner = CGSize(width: 900, height: 300)
        #expect(!SlideDeckHints.looksLikeSlides(pageSizes: Array(repeating: banner, count: 5), opensInFullScreen: false, creator: nil))
    }

    @Test func presentationSoftwareCountsForALandscapeFirstPage() {
        #expect(SlideDeckHints.looksLikeSlides(pageSizes: [fourThree], opensInFullScreen: false, creator: " LaTeX with Beamer class pdfTeX-1.40.26"))
        #expect(SlideDeckHints.looksLikeSlides(pageSizes: [sixteenNine], opensInFullScreen: false, creator: "Microsoft® PowerPoint® for Mac"))
        #expect(!SlideDeckHints.looksLikeSlides(pageSizes: [letter], opensInFullScreen: false, creator: "Keynote"), "a handout printed portrait")
    }

    @Test func aDocumentThatAsksForFullScreenLooksLikeSlides() {
        #expect(SlideDeckHints.looksLikeSlides(pageSizes: [letter], opensInFullScreen: true, creator: nil))
    }

    // MARK: Read from the file

    @Test func readsPageSizesWithTheirRotation() throws {
        let landscape = RawPDF.make(pageRotations: [0, 0, 0], mediaBox: "0 0 362.83 272.13")
        #expect(SlideDeckHints.looksLikeSlides(try document(landscape)))
        // Letter turned by /Rotate 90 appears 792 by 612.
        let turned = RawPDF.make(pageRotations: [90, 90, 90])
        #expect(SlideDeckHints.looksLikeSlides(try document(turned)))
        #expect(!SlideDeckHints.looksLikeSlides(try document(RawPDF.make(pageRotations: [0, 0, 0]))))
    }

    @Test func readsThePageModeAndTheCreator() throws {
        #expect(SlideDeckHints.looksLikeSlides(try document(RawPDF.make(catalogExtras: "/PageMode /FullScreen"))))
        #expect(!SlideDeckHints.looksLikeSlides(try document(RawPDF.make(catalogExtras: "/PageMode /UseOutlines"))))
        let beamer = RawPDF.make(
            trailerExtras: "/Info 4 0 R",
            extraObjects: ["<< /Creator (LaTeX with Beamer class) /Producer (pdfTeX-1.40.26) >>"],
            mediaBox: "0 0 362.83 272.13"
        )
        #expect(SlideDeckHints.looksLikeSlides(try document(beamer)))
    }

    private func document(_ data: Data) throws -> CGPDFDocument {
        try #require(CGDataProvider(data: data as CFData).flatMap(CGPDFDocument.init))
    }
}

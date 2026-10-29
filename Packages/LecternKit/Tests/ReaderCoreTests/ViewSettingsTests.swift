import CoreGraphics
import Foundation
import Testing
@testable import ReaderCore

@Suite struct ViewSettingsTests {
    @Test func defaultsToSingleContinuousFitWidth() {
        let settings = ViewSettings()
        #expect(settings.pages == .single)
        #expect(settings.scrolling == .continuous)
        #expect(settings.zoom == .fitWidth)
        #expect(settings.rotation == 0)
        #expect(settings.coverPageAlone == nil)
        #expect(settings.rightToLeft == nil)
    }

    @Test func roundTripsThroughJSON() throws {
        var settings = ViewSettings(pages: .twoUp, scrolling: .paged, coverPageAlone: true, rightToLeft: false, zoom: .scale(1.5))
        settings.rotateRight()
        let decoded = try JSONDecoder().decode(ViewSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
        #expect(decoded.rotation == 90)
    }

    @Test func fitModesRoundTripThroughJSON() throws {
        for mode in [ZoomMode.fitPage, .fitWidth, .actualSize] {
            let decoded = try JSONDecoder().decode(ZoomMode.self, from: JSONEncoder().encode(mode))
            #expect(decoded == mode)
        }
    }

    // MARK: Cover page and direction

    @Test func coverPageFollowsHintUntilOverridden() {
        let book = DocumentLayoutHints(coverPageAlone: true, rightToLeft: false)
        var settings = ViewSettings()
        #expect(settings.effectiveCoverPageAlone(hints: book))
        #expect(!settings.effectiveCoverPageAlone(hints: .none))

        settings.toggleCoverPageAlone(hints: book)
        #expect(settings.coverPageAlone == false)
        #expect(!settings.effectiveCoverPageAlone(hints: book))

        settings.toggleCoverPageAlone(hints: book)
        #expect(settings.effectiveCoverPageAlone(hints: book))
    }

    @Test func rightToLeftFollowsHintUntilOverridden() {
        let r2l = DocumentLayoutHints(coverPageAlone: false, rightToLeft: true)
        var settings = ViewSettings()
        #expect(settings.effectiveRightToLeft(hints: r2l))
        settings.toggleRightToLeft(hints: r2l)
        #expect(!settings.effectiveRightToLeft(hints: r2l))
        #expect(settings.rightToLeft == false)
    }

    // MARK: Rotation

    @Test func rotatesInQuarterTurnsAndWraps() {
        var settings = ViewSettings()
        settings.rotateLeft()
        #expect(settings.rotation == 270)
        settings.rotateRight()
        settings.rotateRight()
        #expect(settings.rotation == 90)
        for _ in 0..<4 { settings.rotateRight() }
        #expect(settings.rotation == 90)
    }

    @Test(arguments: [(0, 0), (90, 90), (360, 0), (450, 90), (-90, 270), (-450, 270), (100, 90), (-1, 270)])
    func normalizesRotation(input: Int, expected: Int) {
        #expect(ViewSettings.normalized(input) == expected)
        #expect(ViewSettings(rotation: input).rotation == expected)
    }

    // MARK: Zoom

    @Test func zoomStepsMoveAlongTheLadder() {
        var settings = ViewSettings()
        settings.zoomIn(from: 1)
        #expect(settings.zoom == .scale(1.1))
        settings.zoomOut(from: 1.1)
        #expect(settings.zoom == .scale(1))
        settings.zoomOut(from: 1)
        #expect(settings.zoom == .scale(0.9))
    }

    @Test func zoomFromAFitScaleSnapsToTheNextStep() {
        #expect(ZoomMode.step(after: 1.37) == 1.5)
        #expect(ZoomMode.step(before: 1.37) == 1.25)
    }

    @Test func zoomIsClamped() {
        #expect(ZoomMode.step(after: ZoomMode.maximumScale) == ZoomMode.maximumScale)
        #expect(ZoomMode.step(before: ZoomMode.minimumScale) == ZoomMode.minimumScale)
        #expect(ZoomMode.step(after: 20) == ZoomMode.maximumScale)
    }

    @Test func onlyFitModesAreFit() {
        #expect(ZoomMode.fitPage.isFit)
        #expect(ZoomMode.fitWidth.isFit)
        #expect(!ZoomMode.actualSize.isFit)
    }
}

@Suite struct DocumentLayoutHintsTests {
    private func hints(_ data: Data) throws -> DocumentLayoutHints {
        let provider = try #require(CGDataProvider(data: data as CFData))
        let document = try #require(CGPDFDocument(provider))
        return DocumentLayoutHints(document: document)
    }

    @Test func plainDocumentHasNoHints() throws {
        #expect(try hints(RawPDF.make()) == .none)
    }

    @Test(arguments: ["TwoPageRight", "TwoColumnRight"])
    func rightHandLayoutsPutTheCoverAlone(layout: String) throws {
        #expect(try hints(RawPDF.make(catalogExtras: "/PageLayout /\(layout)")).coverPageAlone)
    }

    @Test(arguments: ["SinglePage", "OneColumn", "TwoPageLeft", "TwoColumnLeft"])
    func otherLayoutsDoNot(layout: String) throws {
        #expect(try !hints(RawPDF.make(catalogExtras: "/PageLayout /\(layout)")).coverPageAlone)
    }

    @Test func readsRightToLeftDirection() throws {
        let result = try hints(RawPDF.make(catalogExtras: "/ViewerPreferences << /Direction /R2L >>"))
        #expect(result.rightToLeft)
        #expect(!result.coverPageAlone)
    }

    @Test func leftToRightDirectionIsNotRightToLeft() throws {
        #expect(try !hints(RawPDF.make(catalogExtras: "/ViewerPreferences << /Direction /L2R >>")).rightToLeft)
    }
}

@Suite struct DocumentKeyTests {
    @Test func usesFirstIdentifierAsHex() {
        let data = RawPDF.make(trailerExtras: "/ID [<00A1B2c3> <FFFF>]")
        #expect(DocumentKey(pdfData: data).rawValue == "id:00a1b2c3")
    }

    @Test func sameIdentifierGivesSameKeyAcrossEdits() {
        let a = RawPDF.make(trailerExtras: "/ID [<0102> <0304>]")
        let b = RawPDF.make(catalogExtras: "/PageLayout /TwoPageRight", trailerExtras: "/ID [<0102> <0506>]")
        #expect(DocumentKey(pdfData: a) == DocumentKey(pdfData: b))
    }

    @Test func fallsBackToHashOfFirst64KB() {
        let data = RawPDF.make()
        let key = DocumentKey(pdfData: data)
        #expect(key.rawValue.hasPrefix("sha256:"))
        #expect(key.rawValue.count == "sha256:".count + 64)
        #expect(key == DocumentKey(pdfData: data))
    }

    @Test func emptyIdentifierFallsBackToHash() {
        let data = RawPDF.make(trailerExtras: "/ID [<> <>]")
        #expect(DocumentKey(pdfData: data).rawValue.hasPrefix("sha256:"))
    }

    @Test func hashOnlyCoversTheFirst64KB() {
        let base = RawPDF.make()
        var padded = base + Data(repeating: 0x20, count: DocumentKey.fallbackPrefixLength)
        let first = DocumentKey(pdfData: padded)
        padded.append(contentsOf: Array("% trailing comment\n".utf8))
        #expect(DocumentKey(pdfData: padded) == first)
    }

    @Test func nonPDFStillGetsAKey() {
        #expect(DocumentKey(pdfData: Data("not a pdf".utf8)).rawValue.hasPrefix("sha256:"))
    }
}

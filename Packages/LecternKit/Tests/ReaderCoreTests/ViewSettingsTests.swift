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

    // MARK: Encrypted files

    /// A one-page file with a standard encryption dictionary (object 4) whose
    /// /O and /U are given as raw PDF string syntax.
    private func encrypted(owner: String, user: String, id: String = "<0102> <0304>", extra: String = "") -> Data {
        RawPDF.make(
            catalogExtras: extra,
            trailerExtras: "/ID [\(id)] /Encrypt 4 0 R",
            extraObjects: ["<< /Filter /Standard /V 2 /R 3 /Length 128 /P -3904 /O \(owner) /U \(user) >>"]
        )
    }

    private let ownerA = "<" + String(repeating: "a1", count: 32) + ">"
    private let ownerB = "<" + String(repeating: "b2", count: 32) + ">"
    private let userA = "<" + String(repeating: "c3", count: 32) + ">"

    @Test func encryptedFilesAddTheirPasswordEntriesToTheKey() {
        let key = DocumentKey(pdfData: encrypted(owner: ownerA, user: userA)).rawValue
        #expect(key.hasPrefix("id:0102;enc:"))
        #expect(key.count == "id:0102;enc:".count + 64)
    }

    @Test func reEncryptingWithAnotherPasswordChangesTheKey() {
        // Same /ID first element, different owner password.
        let a = DocumentKey(pdfData: encrypted(owner: ownerA, user: userA))
        let b = DocumentKey(pdfData: encrypted(owner: ownerB, user: userA, id: "<0102> <9999>"))
        #expect(a != b)
    }

    @Test func otherEditsKeepTheKey() {
        let a = DocumentKey(pdfData: encrypted(owner: ownerA, user: userA))
        let b = DocumentKey(pdfData: encrypted(owner: ownerA, user: userA, extra: "/PageLayout /TwoPageRight"))
        #expect(a == b)
    }

    @Test func literalAndHexSpellingsOfTheSameStringsAgree() {
        let hex = DocumentKey(pdfData: encrypted(owner: "<28295c0a>", user: "<41>"))
        let literal = DocumentKey(pdfData: encrypted(owner: #"(\(\)\\\n)"#, user: "(A)"))
        #expect(hex == literal)
    }

    @Test func coreGraphicsEncryptedFilesGetAStableEncryptionKey() throws {
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let info: [CFString: Any] = [kCGPDFContextOwnerPassword: "owner", kCGPDFContextUserPassword: "user"]
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, info as CFDictionary))
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        let key = DocumentKey(pdfData: data as Data)
        #expect(key.rawValue.hasPrefix("id:"))
        #expect(key.rawValue.contains(";enc:"))
        #expect(key == DocumentKey(pdfData: data as Data))
    }
}

@Suite struct PDFTokenScannerTests {
    private func strings(_ syntax: String) -> [String: Data]? {
        var scanner = PDFTokenScanner(Data(syntax.utf8))
        return scanner.dictionaryStrings()
    }

    @Test func readsStringEntriesAndSkipsTheRest() {
        let result = strings("<< /A 1 /B /Name /C [1 (x) <00>] /D << /E (in) >> /F 5 0 R /O (own) /U <75> >>")
        #expect(result == ["O": Data("own".utf8), "U": Data("u".utf8)])
    }

    @Test func decodesLiteralEscapesAndNestedParentheses() {
        #expect(strings(#"<< /O (a(b)c\101\n\)) >>"#)?["O"] == Data("a(b)cA\n)".utf8))
    }

    @Test func padsOddHexDigits() {
        #expect(strings("<< /U <4 1 7> >>")?["U"] == Data([0x41, 0x70]))
    }

    @Test func rejectsTruncatedDictionaries() {
        #expect(strings("<< /O (open") == nil)
        #expect(strings("<< /O (x)") == nil)
    }
}

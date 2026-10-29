import CoreGraphics
import Foundation
import Testing
@testable import ReaderCore

@Suite struct PageNumberingTests {
    private let roman = PageNumbering(labels: ["i", "ii", "iii", "1", "2", "3", "4"], definesLabels: true)

    @Test func plainNumbersPickThePhysicalPage() {
        let plain = PageNumbering(pageCount: 12)
        #expect(plain.pageIndex(for: "1") == .success(0))
        #expect(plain.pageIndex(for: " 12 ") == .success(11))
        #expect(plain.pageIndex(for: "13") == .failure(.noSuchPage("13")))
        #expect(plain.pageIndex(for: "0") == .failure(.noSuchPage("0")))
        #expect(plain.pageIndex(for: "-2") == .failure(.noSuchPage("-2")))
        #expect(plain.pageIndex(for: "ii") == .failure(.noSuchPage("ii")))
        #expect(plain.pageIndex(for: "  ") == .failure(.empty))
    }

    @Test func labelsWinOverPhysicalNumbers() {
        #expect(roman.pageIndex(for: "ii") == .success(1))
        #expect(roman.pageIndex(for: "III") == .success(2))
        // "1" is the label of the fourth page.
        #expect(roman.pageIndex(for: "1") == .success(3))
        // No page is labelled 7, so 7 is the physical page.
        #expect(roman.pageIndex(for: "7") == .success(6))
        #expect(roman.pageIndex(for: "8") == .failure(.noSuchPage("8")))
    }

    @Test func messagesExplainWhatToType() {
        #expect(PageNumbering(pageCount: 5).message(for: .noSuchPage("9")) == "There’s no page “9”. Enter a page number from 1 to 5.")
        #expect(roman.message(for: .empty) == "Enter a page label or a page number from 1 to 7.")
        #expect(roman.message(for: .noSuchPage("x")).contains("such as “i”"))
    }

    @Test func describesPagesByLabelAndNumber() {
        #expect(roman.description(forPageAt: 1) == "Page ii (2 of 7)")
        #expect(PageNumbering(pageCount: 3).description(forPageAt: 2) == "Page 3 of 3")
        #expect(roman.label(forPageAt: 99) == "100")
    }

    @Test func readsWhetherTheCatalogDefinesLabels() throws {
        let labelled = RawPDF.make(catalogExtras: "/PageLabels << /Nums [0 << /S /r >>] >>")
        let plain = RawPDF.make()
        #expect(PageNumbering.definesPageLabels(try #require(document(labelled))))
        #expect(!PageNumbering.definesPageLabels(try #require(document(plain))))
    }

    private func document(_ data: Data) -> CGPDFDocument? {
        CGDataProvider(data: data as CFData).flatMap(CGPDFDocument.init)
    }
}

@Suite struct SearchTextTests {
    private func range(of needle: String, in text: String) -> NSRange {
        (text as NSString).range(of: needle)
    }

    @Test func wholeWordsAreBoundedByNonWordCharacters() {
        let text = "the cat scattered; cat, cats and (cat)" as NSString
        let all = matches(of: "cat", in: text)
        let whole = all.filter { SearchText.isWholeWord($0, in: text) }
        #expect(all.count == 5)
        #expect(whole.count == 3)
    }

    @Test func accentedLettersAreWordCharacters() {
        let text = "café cafés écafé" as NSString
        let whole = matches(of: "café", in: text).filter { SearchText.isWholeWord($0, in: text) }
        #expect(whole == [NSRange(location: 0, length: 4)])
    }

    @Test func matchesAtTheEdgesOfTheTextAreWholeWords() {
        let text = "word" as NSString
        #expect(SearchText.isWholeWord(NSRange(location: 0, length: 4), in: text))
        #expect(!SearchText.isWholeWord(NSRange(location: 0, length: 5), in: text))
        #expect(!SearchText.isWholeWord(NSRange(location: NSNotFound, length: 0), in: text))
    }

    @Test func excerptKeepsTheMatchAndMarksCuts() {
        let text = String(repeating: "alpha beta gamma ", count: 10) + "NEEDLE" + String(repeating: " delta epsilon", count: 10)
        let ns = text as NSString
        let (excerpt, match) = SearchText.excerpt(around: ns.range(of: "NEEDLE"), in: ns, radius: 30)
        #expect((excerpt as NSString).substring(with: match) == "NEEDLE")
        #expect(excerpt.hasPrefix("…"))
        #expect(excerpt.hasSuffix("…"))
        #expect(excerpt.count < 80)
        // Words aren't cut in half.
        #expect(!excerpt.contains("…lpha"))
    }

    @Test func excerptCollapsesLineBreaks() {
        let ns = "first line\n\nsecond   line with word" as NSString
        let (excerpt, match) = SearchText.excerpt(around: ns.range(of: "word"), in: ns)
        #expect(excerpt == "first line second line with word")
        #expect((excerpt as NSString).substring(with: match) == "word")
    }

    @Test func defaultOptionsIgnoreCaseAndAccents() {
        #expect(SearchOptions().compareOptions == [.caseInsensitive, .diacriticInsensitive])
        #expect(SearchOptions(matchCase: true).compareOptions == [.diacriticInsensitive])
    }

    private func matches(of needle: String, in text: NSString) -> [NSRange] {
        var result: [NSRange] = []
        var search = NSRange(location: 0, length: text.length)
        while true {
            let found = text.range(of: needle, options: [], range: search)
            guard found.location != NSNotFound else { return result }
            result.append(found)
            search = NSRange(location: NSMaxRange(found), length: text.length - NSMaxRange(found))
        }
    }
}

@Suite struct SearchSummaryTests {
    @Test func countsResults() {
        #expect(SearchSummary(resultCount: 0, isSearching: false, pagesWithoutText: 0, pageCount: 3).status == "No results")
        #expect(SearchSummary(resultCount: 1, isSearching: false, pagesWithoutText: 0, pageCount: 3).status == "1 result")
        #expect(SearchSummary(resultCount: 4, isSearching: true, pagesWithoutText: nil, pageCount: 3).status == "Searching… 4 results")
        #expect(SearchSummary(resultCount: 0, isSearching: true, pagesWithoutText: nil, pageCount: 3).status == "Searching…")
    }

    @Test func aDocumentWithoutTextSaysSoInsteadOfNoResults() {
        let summary = SearchSummary(resultCount: 0, isSearching: false, pagesWithoutText: 3, pageCount: 3)
        #expect(summary.documentHasNoText)
        #expect(summary.status == "This document has no searchable text")
        #expect(summary.textCoverageNote == nil)
    }

    @Test func aPartlyScannedDocumentSaysHowManyPagesHaveNoText() {
        let summary = SearchSummary(resultCount: 2, isSearching: false, pagesWithoutText: 1, pageCount: 3)
        #expect(summary.status == "2 results")
        #expect(summary.textCoverageNote == "1 page has no searchable text and can’t be searched.")
        let more = SearchSummary(resultCount: 0, isSearching: false, pagesWithoutText: 2, pageCount: 3)
        #expect(more.textCoverageNote == "2 pages have no searchable text and can’t be searched.")
        #expect(more.status == "No results")
    }
}

@Suite struct SidebarSettingsTests {
    @Test func storedWithViewSettings() throws {
        let settings = ViewSettings(sidebar: SidebarSettings(isVisible: true, section: .outline))
        let decoded = try JSONDecoder().decode(ViewSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.sidebar == SidebarSettings(isVisible: true, section: .outline))
    }

    @Test func missingAndUnknownValuesFallBackToDefaults() throws {
        let old = try JSONDecoder().decode(ViewSettings.self, from: Data(#"{"pages":"twoUp","rotation":90}"#.utf8))
        #expect(old.pages == .twoUp)
        #expect(old.rotation == 90)
        #expect(old.zoom == .fitWidth)
        #expect(old.sidebar == SidebarSettings())
        // A section a newer version added falls back to thumbnails.
        let future = try JSONDecoder().decode(SidebarSettings.self, from: Data(#"{"isVisible":true,"section":"layers"}"#.utf8))
        #expect(future == SidebarSettings(isVisible: true, section: .thumbnails))
        let bookmarks = try JSONDecoder().decode(SidebarSettings.self, from: Data(#"{"isVisible":true,"section":"bookmarks"}"#.utf8))
        #expect(bookmarks == SidebarSettings(isVisible: true, section: .bookmarks))
    }
}

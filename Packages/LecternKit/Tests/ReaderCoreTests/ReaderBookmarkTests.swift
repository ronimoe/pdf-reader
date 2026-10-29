import CoreGraphics
import Foundation
import Testing
@testable import ReaderCore

@Suite struct ReaderBookmarkTests {
    private func anchor(_ page: Int, y: CGFloat = 500) -> ReadingAnchor {
        ReadingAnchor(pageIndex: page, pointInPage: CGPoint(x: 10, y: y), scale: 1)
    }

    @Test func toggleAddsThenRemovesOnTheSamePage() {
        var marks: [ReaderBookmark] = []
        #expect(ReaderBookmarks.toggle(at: anchor(3), name: "Page 4", in: &marks).removedName == nil)
        #expect(marks.count == 1)
        #expect(marks.first?.anchor == anchor(3))
        #expect(ReaderBookmarks.toggle(at: anchor(3, y: 100), name: "x", in: &marks).removedName == "Page 4")
        #expect(marks.isEmpty)
    }

    @Test func toggleOnAnotherPageAdds() {
        var marks: [ReaderBookmark] = []
        _ = ReaderBookmarks.toggle(at: anchor(3), name: "a", in: &marks)
        _ = ReaderBookmarks.toggle(at: anchor(4), name: "b", in: &marks)
        #expect(marks.map(\.name) == ["a", "b"])
    }

    @Test func toggleRemovesOnlyTheNearestOfSeveralOnAPage() {
        var marks = [
            ReaderBookmark(name: "top", anchor: anchor(2, y: 700)),
            ReaderBookmark(name: "middle", anchor: anchor(2, y: 400)),
            ReaderBookmark(name: "bottom", anchor: anchor(2, y: 100)),
        ]
        #expect(ReaderBookmarks.toggle(at: anchor(2, y: 380), name: "x", in: &marks).removedName == "middle")
        #expect(marks.map(\.name) == ["top", "bottom"])
    }

    @Test func bookmarksPastTheEndCountOnTheLastPageButOnlyOneGoesAtATime() {
        var marks = [30, 50, 70].map { ReaderBookmark(name: "p\($0)", anchor: anchor($0)) }
        // A 10-page version: all three show on page 10 (index 9).
        #expect(ReaderBookmarks.bookmarks(onPageOf: anchor(9), in: marks, pageCount: 10).count == 3)
        _ = ReaderBookmarks.toggle(at: anchor(9), name: "x", in: &marks, pageCount: 10)
        #expect(marks.count == 2, "a single toggle removes at most one")
        // The stored pages themselves are untouched.
        #expect(Set(marks.map(\.anchor.pageIndex)).isSubset(of: [30, 50, 70]))
    }

    @Test func sortedIsReadingOrder() {
        let t = Date(timeIntervalSince1970: 0)
        let marks = [
            ReaderBookmark(name: "p2 low", anchor: anchor(2, y: 100), created: t),
            ReaderBookmark(name: "p1", anchor: anchor(1), created: t),
            ReaderBookmark(name: "p2 high", anchor: anchor(2, y: 700), created: t),
        ]
        #expect(ReaderBookmarks.sorted(marks).map(\.name) == ["p1", "p2 high", "p2 low"])
    }

    @Test func renameTrimsAndRefusesBlank() {
        let mark = ReaderBookmark(name: "Old", anchor: anchor(0))
        #expect(ReaderBookmarks.renamed(mark.id, to: "  New  ", in: [mark]).first?.name == "New")
        #expect(ReaderBookmarks.renamed(mark.id, to: "  ", in: [mark]).first?.name == "Old")
        #expect(ReaderBookmarks.renamed(UUID(), to: "Other", in: [mark]).first?.name == "Old")
    }

    @Test func clampingMovesPastTheEndOntoTheLastPage() {
        let mark = ReaderBookmark(name: "x", anchor: anchor(9))
        #expect(mark.clamped(toPageCount: 4).anchor.pageIndex == 3)
        #expect(mark.clamped(toPageCount: 4).anchor.pointInPage == mark.anchor.pointInPage)
    }

    @Test func decodesWithDefaultsForMissingFields() throws {
        let json = #"{"anchor":{"pageIndex":2,"pointInPage":[1,2],"scale":1}}"#
        let mark = try JSONDecoder().decode(ReaderBookmark.self, from: Data(json.utf8))
        #expect(mark.anchor.pageIndex == 2)
        #expect(mark.name == "")
    }
}

@Suite struct BookmarkExportTests {
    @Test func exportsTheVersionedSchemaInReadingOrder() throws {
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        let marks = [
            ReaderBookmark(name: "Later", anchor: ReadingAnchor(pageIndex: 5, pointInPage: CGPoint(x: 0, y: 400), scale: 1), created: created),
            ReaderBookmark(name: "Intro", anchor: ReadingAnchor(pageIndex: 0, pointInPage: CGPoint(x: 12.5, y: 700), scale: 2), created: created),
        ]
        let export = BookmarkExport(
            document: .init(title: "A Paper", fileName: "paper.pdf", id: ["aa", "bb"], pageCount: 9),
            bookmarks: marks,
            pageLabel: { $0 == 0 ? "i" : String($0 + 1) },
            exported: created
        )
        let data = try export.encoded()
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["format"] as? String == "io.github.ronimoe.lectern.bookmarks")
        #expect(json["version"] as? Int == 1)
        #expect(json["exported"] as? String == "2027-01-15T08:00:00Z")
        let document = try #require(json["document"] as? [String: Any])
        #expect(document["title"] as? String == "A Paper")
        #expect(document["fileName"] as? String == "paper.pdf")
        #expect(document["id"] as? [String] == ["aa", "bb"])
        #expect(document["pageCount"] as? Int == 9)
        let rows = try #require(json["bookmarks"] as? [[String: Any]])
        #expect(rows.map { $0["name"] as? String } == ["Intro", "Later"])
        #expect(rows.map { $0["pageIndex"] as? Int } == [0, 5])
        #expect(rows.map { $0["pageLabel"] as? String } == ["i", "6"])
        let first = try #require(rows.first?["anchor"] as? [String: Double])
        #expect(first == ["x": 12.5, "y": 700])
        #expect(try BookmarkExport.decode(data) == export)
    }

    @Test func suggestsAFileNameBesideTheDocument() {
        #expect(BookmarkExport.suggestedFileName(forDocumentNamed: "Paper.pdf") == "Paper Bookmarks.json")
        #expect(BookmarkExport.suggestedFileName(forDocumentNamed: "") == "Document Bookmarks.json")
    }
}

extension ReaderBookmarks.Toggle {
    var removedName: String? { if case .removed(let b) = self { b.name } else { nil } }
}

import CoreGraphics
import Foundation
import Testing
@testable import ReaderCore

private func at(_ page: Int, _ y: CGFloat = 700) -> ReadingAnchor {
    ReadingAnchor(pageIndex: page, pointInPage: CGPoint(x: 0, y: y), scale: 1)
}

@Suite struct HistoryStackTests {
    @Test func startsEmpty() {
        let history = HistoryStack()
        #expect(!history.canGoBack)
        #expect(!history.canGoForward)
        #expect(history.isEmpty)
    }

    @Test func backReturnsToWhereEachJumpDeparted() {
        var history = HistoryStack()
        history.recordJump(from: at(1))
        history.recordJump(from: at(10))
        // Now reading page 20.
        #expect(history.goBack(from: at(20)) == at(10))
        #expect(history.goBack(from: at(10)) == at(1))
        #expect(history.goBack(from: at(1)) == nil)
        #expect(history.forwardList == [at(20), at(10)])
    }

    @Test func forwardRetracesBack() {
        var history = HistoryStack()
        history.recordJump(from: at(1))
        let back = history.goBack(from: at(20))
        #expect(back == at(1))
        #expect(history.canGoForward)
        #expect(history.goForward(from: at(1)) == at(20))
        #expect(!history.canGoForward)
        #expect(history.backList == [at(1)])
    }

    @Test func aNewJumpClearsForward() {
        var history = HistoryStack()
        history.recordJump(from: at(1))
        _ = history.goBack(from: at(20))
        history.recordJump(from: at(1, 300))
        #expect(!history.canGoForward)
        #expect(history.backList == [at(1, 300)])
    }

    @Test func theSamePlaceIsNotRecordedTwiceInARow() {
        var history = HistoryStack()
        history.recordJump(from: at(3))
        history.recordJump(from: ReadingAnchor(pageIndex: 3, pointInPage: CGPoint(x: 0.4, y: 700.5), scale: 2))
        #expect(history.backList.count == 1)
        history.recordJump(from: at(3, 100))
        #expect(history.backList.count == 2)
    }

    @Test func keepsOnlyTheNewestEntries() {
        var history = HistoryStack(limit: 3)
        for page in 0..<5 { history.recordJump(from: at(page)) }
        #expect(history.backList == [at(2), at(3), at(4)])
    }

    // MARK: Search sessions (B2)

    @Test func aSearchSessionAddsOneEntryThePositionBeforeSearching() {
        var history = HistoryStack()
        history.beginSearchSession(at: at(5))
        // Refining the query keeps the original start.
        history.beginSearchSession(at: at(6))
        history.willShowSearchResult(from: at(7))
        history.willShowSearchResult(from: at(30))
        history.willShowSearchResult(from: at(40))
        #expect(history.backList == [at(5)])
        history.endSearchSession()
        #expect(history.goBack(from: at(50)) == at(5))
    }

    @Test func aSearchThatShowsNothingAddsNothing() {
        var history = HistoryStack()
        history.beginSearchSession(at: at(5))
        history.endSearchSession()
        #expect(history.isEmpty)
    }

    @Test func eachSessionAddsItsOwnEntry() {
        var history = HistoryStack()
        history.beginSearchSession(at: at(1))
        history.willShowSearchResult(from: at(1))
        history.endSearchSession()
        history.beginSearchSession(at: at(9))
        history.willShowSearchResult(from: at(9))
        history.endSearchSession()
        #expect(history.backList == [at(1), at(9)])
    }

    @Test func backInsideASessionRestartsItFromThere() {
        var history = HistoryStack()
        history.beginSearchSession(at: at(1))
        history.willShowSearchResult(from: at(1))
        #expect(history.goBack(from: at(12)) == at(1))
        // The next result shown departs from page 1 again, not nowhere.
        history.willShowSearchResult(from: at(1))
        #expect(history.backList == [at(1)])
        #expect(history.isInSearchSession)
    }

    @Test func resultsOutsideASessionAreOrdinaryJumps() {
        var history = HistoryStack()
        history.willShowSearchResult(from: at(2))
        #expect(history.backList == [at(2)])
    }

    // MARK: Storage

    @Test func roundTripsThroughJSONWithoutTheSession() throws {
        var history = HistoryStack()
        history.recordJump(from: at(1))
        history.recordJump(from: at(2))
        _ = history.goBack(from: at(3))
        history.beginSearchSession(at: at(4))
        let decoded = try JSONDecoder().decode(HistoryStack.self, from: JSONEncoder().encode(history))
        #expect(decoded.backList == history.backList)
        #expect(decoded.forwardList == history.forwardList)
        #expect(!decoded.isInSearchSession)
    }

    @Test func missingListsDecodeAsEmpty() throws {
        let decoded = try JSONDecoder().decode(HistoryStack.self, from: Data("{}".utf8))
        #expect(decoded.isEmpty)
    }

    @Test func clampsEveryEntryToANewPageCount() {
        var history = HistoryStack()
        history.recordJump(from: at(40))
        history.recordJump(from: at(2))
        _ = history.goBack(from: at(90))
        let clamped = history.clamped(toPageCount: 10)
        #expect(clamped.backList.map(\.pageIndex) == [9])
        #expect(clamped.forwardList.map(\.pageIndex) == [9])
    }

    @Test func paneIDsKeyAJSONObject() throws {
        let histories: [PaneID: HistoryStack] = [.primary: HistoryStack(backList: [at(1)])]
        let json = try #require(String(data: JSONEncoder().encode(histories), encoding: .utf8))
        #expect(json.hasPrefix("{\"primary\""))
        let decoded = try JSONDecoder().decode([PaneID: HistoryStack].self, from: Data(json.utf8))
        #expect(decoded[.primary]?.backList == [at(1)])
    }
}

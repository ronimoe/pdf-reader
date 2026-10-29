import CoreGraphics
import Testing
@testable import ReaderCore

@Suite struct ReadingAnchorTests {
    @Test func clampsPastLastPage() {
        let anchor = ReadingAnchor(pageIndex: 40, pointInPage: CGPoint(x: 10, y: 20), scale: 1.5)
        #expect(anchor.clamped(toPageCount: 12).pageIndex == 11)
    }

    @Test func keepsValidPage() {
        let anchor = ReadingAnchor(pageIndex: 3, pointInPage: .zero, scale: 1)
        #expect(anchor.clamped(toPageCount: 12) == anchor)
    }

    @Test func emptyDocumentClampsToZero() {
        let anchor = ReadingAnchor(pageIndex: 3, pointInPage: .zero, scale: 1)
        #expect(anchor.clamped(toPageCount: 0).pageIndex == 0)
    }
}

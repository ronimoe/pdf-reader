import CoreGraphics

/// A position inside a document: the page, a point in that page's own
/// coordinate space, and the zoom it was captured at.
///
/// Used to keep the reader's place across zoom, resize, layout, rotation and
/// reload, as the stored reading position, and as a history entry.
///
/// The point is the page-space point that was at the top-left corner of the
/// visible area. Page space is the unrotated crop box, so an anchor survives
/// a view rotation (B9) unchanged.
public struct ReadingAnchor: Codable, Hashable, Sendable {
    public var pageIndex: Int
    public var pointInPage: CGPoint
    public var scale: CGFloat

    public init(pageIndex: Int, pointInPage: CGPoint, scale: CGFloat) {
        self.pageIndex = pageIndex
        self.pointInPage = pointInPage
        self.scale = scale
    }

    /// Returns the anchor moved onto a document with `pageCount` pages,
    /// clamping the page index (decision A2: remap by page after a file changes).
    public func clamped(toPageCount pageCount: Int) -> ReadingAnchor {
        var copy = self
        copy.pageIndex = min(max(0, pageIndex), max(0, pageCount - 1))
        return copy
    }

    /// The same page, and points within `tolerance` page points of each
    /// other. The scale is ignored: it doesn't change where the reader is.
    public func isSamePlace(as other: ReadingAnchor, tolerance: CGFloat = 1) -> Bool {
        pageIndex == other.pageIndex
            && abs(pointInPage.x - other.pointInPage.x) <= tolerance
            && abs(pointInPage.y - other.pointInPage.y) <= tolerance
    }
}

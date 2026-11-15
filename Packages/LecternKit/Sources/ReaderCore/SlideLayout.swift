import CoreGraphics

/// Where a page goes on a presentation screen: its box, turned by its rotation, fitted to the
/// screen and centred. Maps points both ways, so a click on the slide can find a link.
///
/// Page space is the page's box unrotated, y up. View space is the slide view's coordinates,
/// y up. `PDFPage.draw(with:to:)` draws the turned box with its bottom-left corner at the origin
/// (measured on macOS 27, for every rotation and for boxes that don't start at the origin), so
/// drawing translates to `frame.origin` and scales by `scale`.
public struct SlideLayout: Equatable, Sendable {
    /// The page's box in page space.
    public let pageBox: CGRect
    /// Clockwise: 0, 90, 180 or 270.
    public let rotation: Int
    /// Where the turned page is drawn, in view space. Empty when nothing can be drawn.
    public let frame: CGRect
    /// View points per page point.
    public let scale: CGFloat

    public init(pageBox: CGRect, rotation: Int, fitting bounds: CGRect) {
        self.pageBox = pageBox
        self.rotation = ViewSettings.normalized(rotation)
        let turned = Self.turnedSize(of: pageBox.size, rotation: self.rotation)
        guard turned.width > 0, turned.height > 0, bounds.width > 0, bounds.height > 0 else {
            scale = 0
            frame = .zero
            return
        }
        let scale = min(bounds.width / turned.width, bounds.height / turned.height)
        let size = CGSize(width: turned.width * scale, height: turned.height * scale)
        // Whole-point origins keep the page's edges sharp.
        let origin = CGPoint(
            x: (bounds.minX + (bounds.width - size.width) / 2).rounded(),
            y: (bounds.minY + (bounds.height - size.height) / 2).rounded()
        )
        self.scale = scale
        frame = CGRect(origin: origin, size: size)
    }

    /// The page's size as it appears, turned by `rotation`.
    public static func turnedSize(of size: CGSize, rotation: Int) -> CGSize {
        ViewSettings.normalized(rotation) % 180 == 0 ? size : CGSize(width: size.height, height: size.width)
    }

    public func viewPoint(forPagePoint point: CGPoint) -> CGPoint {
        let x = point.x - pageBox.minX
        let y = point.y - pageBox.minY
        let width = pageBox.width
        let height = pageBox.height
        let turned: CGPoint = switch rotation {
        case 90: CGPoint(x: y, y: width - x)
        case 180: CGPoint(x: width - x, y: height - y)
        case 270: CGPoint(x: height - y, y: x)
        default: CGPoint(x: x, y: y)
        }
        return CGPoint(x: frame.minX + turned.x * scale, y: frame.minY + turned.y * scale)
    }

    /// The page point under a view point. Meaningful only inside `frame`.
    public func pagePoint(forViewPoint point: CGPoint) -> CGPoint {
        guard scale > 0 else { return .zero }
        let u = (point.x - frame.minX) / scale
        let v = (point.y - frame.minY) / scale
        let width = pageBox.width
        let height = pageBox.height
        let page: CGPoint = switch rotation {
        case 90: CGPoint(x: width - v, y: u)
        case 180: CGPoint(x: width - u, y: height - v)
        case 270: CGPoint(x: v, y: height - u)
        default: CGPoint(x: u, y: v)
        }
        return CGPoint(x: page.x + pageBox.minX, y: page.y + pageBox.minY)
    }

    /// A page rectangle (a link's bounds, say) in view space.
    public func viewRect(forPageRect rect: CGRect) -> CGRect {
        let a = viewPoint(forPagePoint: CGPoint(x: rect.minX, y: rect.minY))
        let b = viewPoint(forPagePoint: CGPoint(x: rect.maxX, y: rect.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}

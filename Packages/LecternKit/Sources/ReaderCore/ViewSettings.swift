import CoreGraphics

/// How one document is laid out on screen (decisions B1 and B9).
///
/// Pages and Scrolling are independent toggles that together give the four
/// layouts. The cover-page and right-to-left values are optional overrides:
/// `nil` means "follow the document's own hint" (`DocumentLayoutHints`).
public struct ViewSettings: Codable, Hashable, Sendable {
    public enum Pages: String, Codable, Hashable, Sendable, CaseIterable {
        case single
        case twoUp
    }

    public enum Scrolling: String, Codable, Hashable, Sendable, CaseIterable {
        case continuous
        case paged
    }

    public var pages: Pages
    public var scrolling: Scrolling
    /// Show the first page alone in two-up layouts. `nil` follows `/PageLayout`.
    public var coverPageAlone: Bool?
    /// Spreads read right to left. `nil` follows `/ViewerPreferences /Direction`.
    public var rightToLeft: Bool?
    /// View-only rotation applied on top of each page's own `/Rotate`, in
    /// degrees: always 0, 90, 180 or 270 (B9).
    public private(set) var rotation: Int
    public var zoom: ZoomMode
    /// The sidebar's visibility and section (spec §4.1, §5.4). *(Added in M2.)*
    public var sidebar: SidebarSettings

    public init(
        pages: Pages = .single,
        scrolling: Scrolling = .continuous,
        coverPageAlone: Bool? = nil,
        rightToLeft: Bool? = nil,
        rotation: Int = 0,
        zoom: ZoomMode = .fitWidth,
        sidebar: SidebarSettings = SidebarSettings()
    ) {
        self.pages = pages
        self.scrolling = scrolling
        self.coverPageAlone = coverPageAlone
        self.rightToLeft = rightToLeft
        self.rotation = Self.normalized(rotation)
        self.zoom = zoom
        self.sidebar = sidebar
    }

    private enum CodingKeys: String, CodingKey {
        case pages, scrolling, coverPageAlone, rightToLeft, rotation, zoom, sidebar
    }

    /// Every key is optional, so state stored by an older or newer version
    /// still loads: a missing or unreadable value falls back to its default.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ViewSettings()
        self.init(
            pages: (try? container.decodeIfPresent(Pages.self, forKey: .pages)) ?? defaults.pages,
            scrolling: (try? container.decodeIfPresent(Scrolling.self, forKey: .scrolling)) ?? defaults.scrolling,
            coverPageAlone: (try? container.decodeIfPresent(Bool.self, forKey: .coverPageAlone)) ?? nil,
            rightToLeft: (try? container.decodeIfPresent(Bool.self, forKey: .rightToLeft)) ?? nil,
            rotation: (try? container.decodeIfPresent(Int.self, forKey: .rotation)) ?? 0,
            zoom: (try? container.decodeIfPresent(ZoomMode.self, forKey: .zoom)) ?? defaults.zoom,
            sidebar: (try? container.decodeIfPresent(SidebarSettings.self, forKey: .sidebar)) ?? defaults.sidebar
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pages, forKey: .pages)
        try container.encode(scrolling, forKey: .scrolling)
        try container.encodeIfPresent(coverPageAlone, forKey: .coverPageAlone)
        try container.encodeIfPresent(rightToLeft, forKey: .rightToLeft)
        try container.encode(rotation, forKey: .rotation)
        try container.encode(zoom, forKey: .zoom)
        try container.encode(sidebar, forKey: .sidebar)
    }

    // MARK: Cover page and direction

    public func effectiveCoverPageAlone(hints: DocumentLayoutHints) -> Bool {
        coverPageAlone ?? hints.coverPageAlone
    }

    public func effectiveRightToLeft(hints: DocumentLayoutHints) -> Bool {
        rightToLeft ?? hints.rightToLeft
    }

    /// Flips the cover-page setting relative to what is currently shown, so
    /// the override always wins over the document hint.
    public mutating func toggleCoverPageAlone(hints: DocumentLayoutHints) {
        coverPageAlone = !effectiveCoverPageAlone(hints: hints)
    }

    public mutating func toggleRightToLeft(hints: DocumentLayoutHints) {
        rightToLeft = !effectiveRightToLeft(hints: hints)
    }

    // MARK: Rotation

    public mutating func rotateLeft() { rotation = Self.normalized(rotation - 90) }
    public mutating func rotateRight() { rotation = Self.normalized(rotation + 90) }

    /// Maps any multiple of 90 (including negatives) into 0..<360. Values that
    /// aren't multiples of 90 are snapped down, as PDF `/Rotate` requires.
    public static func normalized(_ degrees: Int) -> Int {
        let snapped = degrees - (((degrees % 90) + 90) % 90)
        return ((snapped % 360) + 360) % 360
    }

    // MARK: Zoom

    /// Zooms in one step from `currentScale`; the result is always a fixed scale.
    public mutating func zoomIn(from currentScale: CGFloat) {
        zoom = .scale(ZoomMode.step(after: currentScale))
    }

    public mutating func zoomOut(from currentScale: CGFloat) {
        zoom = .scale(ZoomMode.step(before: currentScale))
    }
}

/// How the zoom is chosen. The fit modes are recomputed whenever the view's
/// size or layout changes; `scale` stays fixed.
public enum ZoomMode: Codable, Hashable, Sendable {
    case fitPage
    case fitWidth
    case scale(CGFloat)

    public static let actualSize = ZoomMode.scale(1)

    public static let minimumScale: CGFloat = 0.1
    public static let maximumScale: CGFloat = 8

    /// The ladder Zoom In and Zoom Out move along.
    public static let steps: [CGFloat] = [
        0.1, 0.25, 0.33, 0.5, 0.67, 0.75, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5, 6, 8,
    ]

    /// The next step strictly above `scale` (with a little tolerance, so a
    /// scale that is already on a step moves to the next one).
    public static func step(after scale: CGFloat) -> CGFloat {
        steps.first { $0 > scale * 1.01 } ?? maximumScale
    }

    public static func step(before scale: CGFloat) -> CGFloat {
        steps.last { $0 < scale * 0.99 } ?? minimumScale
    }

    public var isFit: Bool {
        switch self {
        case .fitPage, .fitWidth: true
        case .scale: false
        }
    }
}

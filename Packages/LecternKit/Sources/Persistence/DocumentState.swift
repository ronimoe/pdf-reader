import Foundation
import ReaderCore

/// Everything remembered about one document on this Mac (A2, spec §5.4).
/// Never written into the PDF.
///
/// Every field decodes with a default, so state written by another version
/// still loads.
public struct DocumentState: Codable, Hashable, Sendable {
    public var identity: DocumentIdentity
    public var lastOpened: Date
    /// Where reading was when the document was last seen (Journey A step 5).
    public var anchor: ReadingAnchor?
    /// One history per pane (B2).
    public var history: [PaneID: HistoryStack]
    public var viewSettings: ViewSettings
    /// The split view (B3), or nil for a single pane. `anchor` is always the
    /// first pane's place.
    public var split: SplitState?
    /// Reader bookmarks (A2), in reading order. Exported as JSON on request,
    /// never written into the PDF.
    public var bookmarks: [ReaderBookmark]

    public init(
        identity: DocumentIdentity,
        lastOpened: Date = Date(),
        anchor: ReadingAnchor? = nil,
        history: [PaneID: HistoryStack] = [:],
        viewSettings: ViewSettings = ViewSettings(),
        split: SplitState? = nil,
        bookmarks: [ReaderBookmark] = []
    ) {
        self.identity = identity
        self.lastOpened = lastOpened
        self.anchor = anchor
        self.history = history
        self.viewSettings = viewSettings
        self.split = split
        self.bookmarks = bookmarks
    }

    /// The positions moved onto a file that changed at the same place and
    /// now has `pageCount` pages (A2: remap by page, clamp).
    public func clamped(toPageCount pageCount: Int) -> DocumentState {
        var copy = self
        copy.anchor = anchor?.clamped(toPageCount: pageCount)
        copy.history = history.mapValues { $0.clamped(toPageCount: pageCount) }
        copy.split?.secondaryAnchor = split?.secondaryAnchor?.clamped(toPageCount: pageCount)
        copy.bookmarks = bookmarks.map { $0.clamped(toPageCount: pageCount) }
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case identity, lastOpened, anchor, history, viewSettings, split, bookmarks
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identity = try container.decode(DocumentIdentity.self, forKey: .identity)
        lastOpened = (try? container.decodeIfPresent(Date.self, forKey: .lastOpened)) ?? .distantPast
        anchor = (try? container.decodeIfPresent(ReadingAnchor.self, forKey: .anchor)) ?? nil
        history = (try? container.decodeIfPresent([PaneID: HistoryStack].self, forKey: .history)) ?? [:]
        viewSettings = (try? container.decodeIfPresent(ViewSettings.self, forKey: .viewSettings)) ?? ViewSettings()
        split = (try? container.decodeIfPresent(SplitState.self, forKey: .split)) ?? nil
        bookmarks = (try? container.decodeIfPresent([ReaderBookmark].self, forKey: .bookmarks)) ?? []
    }
}

/// A split tab's second pane (B3): its place, its zoom, and which pane had
/// focus. Its history is stored under `PaneID.secondary` in
/// `DocumentState.history`; the first pane's zoom is `ViewSettings.zoom`.
public struct SplitState: Codable, Hashable, Sendable {
    public var secondaryAnchor: ReadingAnchor?
    public var focusedPane: PaneID
    /// Nil in state written before panes kept their own zoom: the second
    /// pane then takes the first pane's.
    public var secondaryZoom: ZoomMode?

    public init(secondaryAnchor: ReadingAnchor?, focusedPane: PaneID = .primary, secondaryZoom: ZoomMode? = nil) {
        self.secondaryAnchor = secondaryAnchor
        self.focusedPane = focusedPane
        self.secondaryZoom = secondaryZoom
    }

    private enum CodingKeys: String, CodingKey {
        case secondaryAnchor, focusedPane, secondaryZoom
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        secondaryAnchor = (try? container.decodeIfPresent(ReadingAnchor.self, forKey: .secondaryAnchor)) ?? nil
        focusedPane = (try? container.decodeIfPresent(PaneID.self, forKey: .focusedPane)) ?? .primary
        secondaryZoom = (try? container.decodeIfPresent(ZoomMode.self, forKey: .secondaryZoom)) ?? nil
    }
}

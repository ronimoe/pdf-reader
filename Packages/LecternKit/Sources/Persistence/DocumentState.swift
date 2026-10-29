import Foundation
import ReaderCore

/// Everything remembered about one document on this Mac (A2, spec §5.4).
/// Never written into the PDF.
///
/// Reader bookmarks (M5) are added here later. Every field decodes with a
/// default, so state written by another version still loads.
public struct DocumentState: Codable, Hashable, Sendable {
    public var identity: DocumentIdentity
    public var lastOpened: Date
    /// Where reading was when the document was last seen (Journey A step 5).
    public var anchor: ReadingAnchor?
    /// One history per pane (B2).
    public var history: [PaneID: HistoryStack]
    public var viewSettings: ViewSettings

    public init(
        identity: DocumentIdentity,
        lastOpened: Date = Date(),
        anchor: ReadingAnchor? = nil,
        history: [PaneID: HistoryStack] = [:],
        viewSettings: ViewSettings = ViewSettings()
    ) {
        self.identity = identity
        self.lastOpened = lastOpened
        self.anchor = anchor
        self.history = history
        self.viewSettings = viewSettings
    }

    /// The positions moved onto a file that changed at the same place and
    /// now has `pageCount` pages (A2: remap by page, clamp).
    public func clamped(toPageCount pageCount: Int) -> DocumentState {
        var copy = self
        copy.anchor = anchor?.clamped(toPageCount: pageCount)
        copy.history = history.mapValues { $0.clamped(toPageCount: pageCount) }
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case identity, lastOpened, anchor, history, viewSettings
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identity = try container.decode(DocumentIdentity.self, forKey: .identity)
        lastOpened = (try? container.decodeIfPresent(Date.self, forKey: .lastOpened)) ?? .distantPast
        anchor = (try? container.decodeIfPresent(ReadingAnchor.self, forKey: .anchor)) ?? nil
        history = (try? container.decodeIfPresent([PaneID: HistoryStack].self, forKey: .history)) ?? [:]
        viewSettings = (try? container.decodeIfPresent(ViewSettings.self, forKey: .viewSettings)) ?? ViewSettings()
    }
}

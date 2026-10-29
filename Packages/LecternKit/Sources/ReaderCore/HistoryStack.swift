import CoreGraphics

/// Identifies one reading pane inside a tab. Each pane keeps its own history
/// (B2). There is one pane until the split view lands in M3.
public struct PaneID: RawRepresentable, Codable, Hashable, Sendable, CodingKeyRepresentable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let primary = PaneID(rawValue: "primary")
    public static let secondary = PaneID(rawValue: "secondary")

    public var description: String { rawValue }

    public var codingKey: any CodingKey { StringKey(rawValue) }

    public init?<T: CodingKey>(codingKey: T) {
        self.init(rawValue: codingKey.stringValue)
    }

    private struct StringKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

/// One pane's back and forward lists (decision B2).
///
/// **What adds an entry:** a jump — following a link, the outline, a
/// thumbnail, go-to-page and later bookmarks and the preview's Go. The entry
/// is the position the jump departed from.
///
/// **What doesn't:** scrolling, and stepping through search results. A whole
/// search session adds one entry, the position just before the search started,
/// and only once a result is actually shown (a search that never moves the
/// view leaves nothing to go back to).
public struct HistoryStack: Hashable, Sendable {
    public static let defaultLimit = 100

    /// Oldest first; the last element is where Back goes.
    public private(set) var backList: [ReadingAnchor]
    /// The last element is where Forward goes.
    public private(set) var forwardList: [ReadingAnchor]
    public let limit: Int

    /// The open search session, if any. Never stored: a session ends with the
    /// window.
    private var searchSession: SearchSession?

    private struct SearchSession: Hashable, Sendable {
        var start: ReadingAnchor
        var hasRecorded = false
    }

    public init(backList: [ReadingAnchor] = [], forwardList: [ReadingAnchor] = [], limit: Int = Self.defaultLimit) {
        self.limit = max(1, limit)
        self.backList = Array(backList.suffix(self.limit))
        self.forwardList = Array(forwardList.suffix(self.limit))
    }

    public var canGoBack: Bool { !backList.isEmpty }
    public var canGoForward: Bool { !forwardList.isEmpty }
    public var isEmpty: Bool { backList.isEmpty && forwardList.isEmpty }

    // MARK: Jumps

    /// Records a jump that leaves `departure`. Clears the forward list, as a
    /// browser does. A departure that is the same place as the newest back
    /// entry isn't recorded twice.
    public mutating func recordJump(from departure: ReadingAnchor) {
        forwardList.removeAll()
        if let last = backList.last, last.isSamePlace(as: departure) { return }
        backList.append(departure)
        if backList.count > limit { backList.removeFirst(backList.count - limit) }
    }

    /// Moves one step back. `current` goes onto the forward list; returns
    /// where to go, or nil if there is nothing to go back to.
    public mutating func goBack(from current: ReadingAnchor) -> ReadingAnchor? {
        guard let target = backList.popLast() else { return nil }
        forwardList.append(current)
        if forwardList.count > limit { forwardList.removeFirst(forwardList.count - limit) }
        restartSearchSession(at: target)
        return target
    }

    public mutating func goForward(from current: ReadingAnchor) -> ReadingAnchor? {
        guard let target = forwardList.popLast() else { return nil }
        backList.append(current)
        if backList.count > limit { backList.removeFirst(backList.count - limit) }
        restartSearchSession(at: target)
        return target
    }

    // MARK: Search sessions

    public var isInSearchSession: Bool { searchSession != nil }

    /// Starts a search session at `position`, the place reading was when the
    /// search began. Does nothing if a session is already open, so refining
    /// the query keeps the original starting point.
    public mutating func beginSearchSession(at position: ReadingAnchor) {
        guard searchSession == nil else { return }
        searchSession = SearchSession(start: position)
    }

    /// Call before showing a search result. The first result shown in a
    /// session records the session's starting point; later ones add nothing.
    /// Outside a session this records `current` like any other jump.
    public mutating func willShowSearchResult(from current: ReadingAnchor) {
        guard var session = searchSession else {
            recordJump(from: current)
            return
        }
        guard !session.hasRecorded else { return }
        recordJump(from: session.start)
        session.hasRecorded = true
        searchSession = session
    }

    public mutating func endSearchSession() {
        searchSession = nil
    }

    /// After Back or Forward inside a search session, the next result shown
    /// departs from where the user now is.
    private mutating func restartSearchSession(at position: ReadingAnchor) {
        guard searchSession != nil else { return }
        searchSession = SearchSession(start: position)
    }

    // MARK: Remapping

    /// The history moved onto a document with `pageCount` pages (A2: a file
    /// that changed at the same path keeps its history, remapped by page).
    public func clamped(toPageCount pageCount: Int) -> HistoryStack {
        var copy = self
        copy.backList = backList.map { $0.clamped(toPageCount: pageCount) }
        copy.forwardList = forwardList.map { $0.clamped(toPageCount: pageCount) }
        copy.searchSession = searchSession.map {
            SearchSession(start: $0.start.clamped(toPageCount: pageCount), hasRecorded: $0.hasRecorded)
        }
        return copy
    }
}

extension HistoryStack: Codable {
    private enum CodingKeys: String, CodingKey {
        case backList = "back"
        case forwardList = "forward"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            backList: try container.decodeIfPresent([ReadingAnchor].self, forKey: .backList) ?? [],
            forwardList: try container.decodeIfPresent([ReadingAnchor].self, forKey: .forwardList) ?? []
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(backList, forKey: .backList)
        try container.encode(forwardList, forKey: .forwardList)
    }
}

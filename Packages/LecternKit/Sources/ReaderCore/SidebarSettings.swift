/// The sidebar's sections (spec §4.1). One is shown at a time.
///
/// Bookmarks (M5) and annotations (M4) are added here as further cases; the
/// order of `allCases` is the order of the section picker.
public enum SidebarSection: String, Codable, Hashable, Sendable, CaseIterable {
    case thumbnails
    case outline
    case search

    public var title: String {
        switch self {
        case .thumbnails: "Thumbnails"
        case .outline: "Table of Contents"
        case .search: "Search Results"
        }
    }

    /// An SF Symbol for the section picker.
    public var symbolName: String {
        switch self {
        case .thumbnails: "square.grid.2x2"
        case .outline: "list.bullet.indent"
        case .search: "magnifyingglass"
        }
    }
}

/// Whether the sidebar shows, and which section. Remembered per document.
public struct SidebarSettings: Codable, Hashable, Sendable {
    public var isVisible: Bool
    public var section: SidebarSection

    public init(isVisible: Bool = false, section: SidebarSection = .thumbnails) {
        self.isVisible = isVisible
        self.section = section
    }

    private enum CodingKeys: String, CodingKey {
        case isVisible, section
    }

    /// An unknown section (stored by a newer version) falls back to thumbnails.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isVisible = (try? container.decodeIfPresent(Bool.self, forKey: .isVisible)) ?? false
        section = (try? container.decodeIfPresent(SidebarSection.self, forKey: .section)) ?? .thumbnails
    }
}

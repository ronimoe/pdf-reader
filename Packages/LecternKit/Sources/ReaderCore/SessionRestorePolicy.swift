/// Whether Lectern reopens last session's documents at launch (B3, spec §5.4). Set in Settings ▸
/// General.
public enum SessionRestorePolicy: String, CaseIterable, Codable, Sendable {
    /// Follow macOS: System Settings ▸ Desktop & Dock ▸ "Close windows when quitting an
    /// application". Restore only when that is off.
    case system
    case always
    case never

    public static let `default` = SessionRestorePolicy.system

    public var title: String {
        switch self {
        case .system: "As set in System Settings"
        case .always: "Always"
        case .never: "Never"
        }
    }

    /// `systemKeepsWindows` is macOS's `NSQuitAlwaysKeepsWindows`: true when "Close windows when
    /// quitting an application" is off.
    public func shouldRestore(systemKeepsWindows: Bool) -> Bool {
        switch self {
        case .system: systemKeepsWindows
        case .always: true
        case .never: false
        }
    }
}

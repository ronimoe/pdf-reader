import AppKit
import SwiftUI

/// Every keyboard shortcut, read from the running main menu so the list can't drift from it
/// (Help ▸ Keyboard Shortcuts, Rule 8).
enum KeyboardShortcutCatalog {
    struct Entry: Identifiable, Hashable {
        var id: String { "\(menu)|\(title)|\(keys)" }
        /// The top-level menu.
        let menu: String
        /// "Find ▸ Find Next" for items in submenus.
        let title: String
        /// "⌃⌘S"
        let keys: String
    }

    struct Group: Identifiable, Hashable {
        var id: String { menu }
        let menu: String
        let entries: [Entry]
    }

    /// The items that carry a shortcut someone can see in the menu: visible, with a key
    /// equivalent. Hidden alternates (⌘= for Zoom In, AppKit's spare ⌃⌘F) work, but aren't listed.
    static func shortcutItems(in menu: NSMenu) -> [(path: [String], item: NSMenuItem)] {
        var found: [(path: [String], item: NSMenuItem)] = []
        func walk(_ menu: NSMenu, _ path: [String]) {
            for item in menu.items {
                if let submenu = item.submenu {
                    guard !item.isHidden else { continue }
                    walk(submenu, path + [item.title])
                } else if !item.isHidden, !item.isSeparatorItem, !item.keyEquivalent.isEmpty {
                    found.append((path, item))
                }
            }
        }
        walk(menu, [])
        return found
    }

    /// Grouped by top-level menu, in menu order.
    static func groups(from menu: NSMenu) -> [Group] {
        var order: [String] = []
        var byMenu: [String: [Entry]] = [:]
        for (path, item) in shortcutItems(in: menu) {
            guard let top = path.first else { continue }
            let title = (Array(path.dropFirst()) + [item.title]).joined(separator: " ▸ ")
            if byMenu[top] == nil { order.append(top) }
            byMenu[top, default: []].append(Entry(menu: top, title: title, keys: keys(for: item)))
        }
        return order.map { Group(menu: $0, entries: byMenu[$0] ?? []) }
    }

    /// The shortcut as the menu draws it: modifiers in ⌃⌥⇧⌘ order, then the key.
    static func keys(for item: NSMenuItem) -> String {
        var key = item.keyEquivalent
        var modifiers = item.keyEquivalentModifierMask
        // An uppercase letter means Shift.
        if key.count == 1, let scalar = key.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(scalar) {
            modifiers.insert(.shift)
            key = key.lowercased()
        }
        var text = ""
        if modifiers.contains(.function) { text += "fn " }
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + glyph(for: key)
    }

    static func glyph(for key: String) -> String {
        guard let scalar = key.unicodeScalars.first else { return key }
        switch Int(scalar.value) {
        case 0x09: return "⇥"
        case 0x0D, 0x03: return "↩"
        case 0x1B: return "⎋"
        case 0x20: return "Space"
        case 0x08, 0x7F: return "⌫"
        case NSDeleteFunctionKey: return "⌦"
        case NSUpArrowFunctionKey: return "↑"
        case NSDownArrowFunctionKey: return "↓"
        case NSLeftArrowFunctionKey: return "←"
        case NSRightArrowFunctionKey: return "→"
        case NSHomeFunctionKey: return "↖"
        case NSEndFunctionKey: return "↘"
        case NSPageUpFunctionKey: return "⇞"
        case NSPageDownFunctionKey: return "⇟"
        default: return key.uppercased()
        }
    }
}

/// The list, in a small window.
struct KeyboardShortcutsView: View {
    let groups: [KeyboardShortcutCatalog.Group]

    var body: some View {
        List {
            ForEach(groups) { group in
                Section(group.menu) {
                    ForEach(group.entries) { entry in
                        HStack {
                            Text(entry.title)
                            Spacer(minLength: 16)
                            Text(entry.keys)
                                .font(.body.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(entry.title): \(Self.spoken(entry.keys))")
                    }
                }
            }
        }
        .listStyle(.inset)
        .frame(minWidth: 380, idealWidth: 420, minHeight: 360, idealHeight: 560)
    }

    /// "Control Command S" rather than symbols for VoiceOver.
    static func spoken(_ keys: String) -> String {
        let names: [Character: String] = ["⌃": "Control", "⌥": "Option", "⇧": "Shift", "⌘": "Command", "⇥": "Tab", "⌫": "Delete", "↑": "Up Arrow", "↓": "Down Arrow", "←": "Left Arrow", "→": "Right Arrow", "⎋": "Escape", "↩": "Return"]
        var words: [String] = []
        var rest = ""
        for character in keys {
            if let name = names[character] { words.append(name) } else { rest.append(character) }
        }
        let tail = rest.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { words.append(tail) }
        return words.joined(separator: " ")
    }
}

/// Help ▸ Keyboard Shortcuts. Rebuilt from the live menu every time it is shown.
final class KeyboardShortcutsWindowController: NSWindowController {
    private let hosting: NSHostingController<KeyboardShortcutsView>
    private let sourceMenu: () -> NSMenu?

    init(menu: @escaping () -> NSMenu? = { NSApp.mainMenu }) {
        sourceMenu = menu
        hosting = NSHostingController(rootView: KeyboardShortcutsView(groups: []))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Keyboard Shortcuts"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.isRestorable = false
        window.setContentSize(NSSize(width: 420, height: 560))
        super.init(window: window)
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private(set) var groups: [KeyboardShortcutCatalog.Group] = []

    func reload() {
        groups = sourceMenu().map(KeyboardShortcutCatalog.groups(from:)) ?? []
        hosting.rootView = KeyboardShortcutsView(groups: groups)
    }

    func show() {
        reload()
        guard let window else { return }
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    override func cancelOperation(_ sender: Any?) {
        window?.performClose(sender)
    }
}

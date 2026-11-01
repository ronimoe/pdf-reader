import AppKit
import ReaderKit
import SwiftUI
import Testing
@testable import Lectern

/// An in-process accessibility audit (spec §9.3, Rule 8). It walks a window's views and, for
/// SwiftUI content, its accessibility tree, and reports:
/// - an interactive element with no accessible name (label, title or image description),
/// - an AppKit control that refuses first responder, so the keyboard can't reach it, unless it is
///   deliberately kept out of focus and reachable another way (`exemptFromFocus`),
/// - a segmented control segment with no name.
/// It checks what doesn't depend on this Mac's settings: `canBecomeKeyView` for buttons depends
/// on Full Keyboard Access, so `refusesFirstResponder`/`acceptsFirstResponder` are used instead.
/// SwiftUI is the exception from macOS 27 (`focusableOnlyWithKeyboardNavigation`).
@MainActor
enum AccessibilityAudit {
    struct Issue: CustomStringConvertible, Equatable {
        let element: String
        let problem: String
        var description: String { "\(element): \(problem)" }
    }

    /// Views whose controls never take focus by design, with the keyboard route that replaces
    /// them. The selection bar must never take focus from the page; every action on it is in the
    /// Annotate menu with a shortcut (⌃⌘H, ⌃⌘U, ⌃⌘X, ⌃⌘K, ⌃⌘1…6).
    static func exemptFromFocus(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let v = current {
            if v is SelectionActionBar { return true }
            current = v.superview
        }
        return false
    }

    static let interactiveRoles: Set<NSAccessibility.Role> = [
        .button, .checkBox, .radioButton, .popUpButton, .menuButton, .textField, .comboBox,
        .slider, .incrementor, .link, .disclosureTriangle,
    ]

    /// SwiftUI controls the keyboard reaches only with Keyboard Navigation on (System Settings ▸
    /// Keyboard). From macOS 27, SwiftUI's accessibility tree follows that setting, as AppKit's
    /// `canBecomeKeyView` does, so their focus is checked only with it on; text fields take focus
    /// either way. macOS 26's SwiftUI reported them focusable regardless.
    static let focusableOnlyWithKeyboardNavigation: Set<NSAccessibility.Role> = [
        .button, .checkBox, .radioButton, .popUpButton, .menuButton, .slider, .incrementor, .disclosureTriangle,
    ]

    static var swiftUIFocusFollowsKeyboardNavigation: Bool {
        if #available(macOS 27, *) { return true }
        return false
    }

    /// The window's content and its toolbar. The title bar's own widgets are AppKit's.
    static func audit(window: NSWindow) -> [Issue] {
        guard let root = window.contentView else { return [] }
        root.layoutSubtreeIfNeeded()
        return withAssistiveTree { audit(view: root) } + audit(toolbar: window.toolbar)
    }

    // MARK: AppKit views

    static func audit(view root: NSView) -> [Issue] {
        var issues: [Issue] = []
        func walk(_ view: NSView) {
            guard !view.isHidden else { return }
            if isHosting(view) {
                issues += audit(accessibilityElement: view, path: name(of: view))
                return
            }
            if let control = view as? NSControl, !(view is NSScroller), isInteractive(control) {
                if accessibleName(of: control).isEmpty {
                    issues.append(Issue(element: name(of: control), problem: "has no accessible name"))
                }
                if control.refusesFirstResponder, !exemptFromFocus(control) {
                    issues.append(Issue(element: name(of: control), problem: "refuses first responder, so the keyboard can't reach it"))
                }
                if let segmented = control as? NSSegmentedControl {
                    for index in 0..<segmented.segmentCount {
                        let label = segmented.label(forSegment: index) ?? ""
                        let image = segmented.image(forSegment: index)?.accessibilityDescription ?? ""
                        let tip = segmented.toolTip(forSegment: index) ?? ""
                        if label.isEmpty && image.isEmpty && tip.isEmpty {
                            issues.append(Issue(element: "\(name(of: control)) segment \(index)", problem: "has no name"))
                        }
                    }
                }
            }
            if let table = view as? NSTableView {
                if (table.accessibilityLabel() ?? "").isEmpty {
                    issues.append(Issue(element: name(of: table), problem: "list has no accessible name"))
                }
                if !table.acceptsFirstResponder {
                    issues.append(Issue(element: name(of: table), problem: "list can't take keyboard focus"))
                }
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        return issues
    }

    /// Labels aren't interactive; editable text fields, buttons, pop-ups, steppers and the like are.
    static func isInteractive(_ control: NSControl) -> Bool {
        if let field = control as? NSTextField, !(control is NSSearchField) { return field.isEditable }
        if let image = control as? NSImageView { return image.isEditable }
        return control.isEnabled || control is NSButton || control is NSPopUpButton || control is NSSegmentedControl
    }

    static func accessibleName(of control: NSControl) -> String {
        let candidates: [String?] = [
            control.accessibilityLabel(),
            control.accessibilityTitle(),
            // An image-only button's title isn't shown or read (AppKit's default is "Button").
            (control as? NSButton).flatMap { $0.imagePosition == .imageOnly ? nil : $0.title },
            (control as? NSButton)?.image?.accessibilityDescription,
            (control as? NSPopUpButton)?.titleOfSelectedItem,
            (control as? NSTextField)?.placeholderString,
        ]
        return candidates.compactMap { $0?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
    }

    static func name(of view: NSView) -> String {
        let label = view.accessibilityLabel() ?? (view as? NSButton)?.title ?? ""
        return "\(type(of: view))\(label.isEmpty ? "" : " “\(label)”")"
    }

    // MARK: Toolbar

    /// Every toolbar item is named, and every button's action is also in the main menu, so the
    /// keyboard can do whatever the toolbar does.
    static func audit(toolbar: NSToolbar?, menu: NSMenu? = MainMenu.make()) -> [Issue] {
        guard let toolbar else { return [] }
        var issues: [Issue] = []
        let menuActions = Set((menu.map(allMenuItems) ?? []).compactMap(\.action))
        for item in toolbar.items {
            let id = item.itemIdentifier.rawValue
            if [NSToolbarItem.Identifier.flexibleSpace, .space, .sidebarTrackingSeparator].contains(item.itemIdentifier) { continue }
            if item.label.isEmpty && (item.image?.accessibilityDescription ?? "").isEmpty {
                issues.append(Issue(element: "toolbar item \(id)", problem: "has no label"))
            }
            if item is NSSearchToolbarItem {
                if !menuActions.contains(#selector(ReaderWindowController.focusSearchField(_:))) {
                    issues.append(Issue(element: "toolbar search field", problem: "Find (⌘F) isn't in the menu"))
                }
            } else if let action = item.action, !menuActions.contains(action) {
                issues.append(Issue(element: "toolbar item \(id)", problem: "\(action) has no menu equivalent"))
            }
            if let search = item as? NSSearchToolbarItem, (search.searchField.accessibilityLabel() ?? "").isEmpty {
                issues.append(Issue(element: "toolbar search field", problem: "has no accessible name"))
            }
            if let menuItem = item as? NSMenuToolbarItem {
                for entry in menuItem.menu.items where !entry.isSeparatorItem && entry.title.isEmpty && !entry.isSectionHeader {
                    issues.append(Issue(element: "toolbar menu \(id)", problem: "an item has no title"))
                }
            }
        }
        return issues
    }

    // MARK: Accessibility tree (SwiftUI)

    /// SwiftUI builds its accessibility nodes only for an assistive client; this asks for them as
    /// VoiceOver does, for the audit's duration. The nodes aren't `NSAccessibilityProtocol` in
    /// Swift's eyes, so they are reached through Objective-C dispatch.
    static func withAssistiveTree<T>(_ body: @MainActor () -> T) -> T {
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        NSApp.accessibilitySetValue(NSNumber(value: true), forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(NSNumber(value: false), forAttribute: attribute) }
        spin(timeout: 0.2) { false }
        return body()
    }

    static func role(of element: Any) -> NSAccessibility.Role? { (element as AnyObject).accessibilityRole?() }
    static func children(of element: Any) -> [Any] { (element as AnyObject).accessibilityChildren?() ?? [] }

    /// An interactive SwiftUI element needs a name and must take keyboard focus.
    static func audit(accessibilityElement root: Any, path: String) -> [Issue] {
        var issues: [Issue] = []
        var visited = 0
        func walk(_ element: Any, depth: Int) {
            guard depth < 40, visited < 5000 else { return }
            visited += 1
            let object = element as AnyObject
            if let role = role(of: element), interactiveRoles.contains(role), !(element is NSScroller) {
                let names = [object.accessibilityLabel?(), object.accessibilityTitle?(), object.accessibilityPlaceholderValue?()]
                if names.allSatisfy({ ($0 ?? nil ?? "").trimmingCharacters(in: .whitespaces).isEmpty }) {
                    issues.append(Issue(element: "\(path) › \(role.rawValue)", problem: "has no accessible name"))
                }
                let enabled = object.isAccessibilityEnabled?() ?? true
                let checksFocus = NSApp.isFullKeyboardAccessEnabled || !swiftUIFocusFollowsKeyboardNavigation
                    || !focusableOnlyWithKeyboardNavigation.contains(role)
                if enabled, checksFocus, let node = element as? NSObject, !node.accessibilityIsAttributeSettable(.focused) {
                    issues.append(Issue(element: "\(path) › \(role.rawValue) “\(names.compactMap { $0 ?? nil }.first ?? "")”", problem: "can't take keyboard focus"))
                }
            }
            // A scroll bar's arrows and page areas are AppKit's own unnamed buttons.
            guard role(of: element) != .scrollBar else { return }
            for child in children(of: element) { walk(child, depth: depth + 1) }
        }
        walk(root, depth: 0)
        return issues
    }

    /// Lays out SwiftUI content in an invisible window so its accessibility tree exists, and audits it.
    static func audit(hostedView view: NSView, size: NSSize = NSSize(width: 480, height: 520)) -> [Issue] {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        M5Harness.prepareInvisible(window)
        window.contentView = view
        window.setFrameOrigin(NSScreen.screens.first?.frame.origin ?? .zero)
        window.orderFrontRegardless()
        view.layoutSubtreeIfNeeded()
        spin(timeout: 0.2) { false }
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        return withAssistiveTree { audit(view: view) }
    }

    static func isHosting(_ view: NSView) -> Bool { String(describing: type(of: view)).hasPrefix("NSHostingView") }

    /// The interactive elements in a hosted view, "role: name", to prove the walk sees SwiftUI.
    static func interactiveElements(in root: Any) -> [String] {
        withAssistiveTree { collectInteractive(root, depth: 0) }
    }

    private static func collectInteractive(_ element: Any, depth: Int) -> [String] {
        guard depth < 40 else { return [] }
        var found: [String] = []
        if let role = role(of: element), interactiveRoles.contains(role) {
            let object = element as AnyObject
            found.append("\(role.rawValue): \((object.accessibilityLabel?() ?? nil) ?? (object.accessibilityTitle?() ?? nil) ?? "")")
        }
        for child in children(of: element) { found += collectInteractive(child, depth: depth + 1) }
        return found
    }
}

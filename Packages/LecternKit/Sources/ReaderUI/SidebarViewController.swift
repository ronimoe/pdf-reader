import AppKit
import ReaderCore

/// One section of the sidebar. Subclass it, give it a `SidebarSection`
/// case, and pass it to `SidebarViewController`; the picker and the section
/// switching come for free. Bookmarks (M5) and annotations (M4) are added
/// this way.
open class SidebarSectionViewController: NSViewController {
    public let section: SidebarSection

    public init(section: SidebarSection) {
        self.section = section
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The view that should take keyboard focus when the section is shown.
    open var preferredFirstResponder: NSView? { nil }
}

/// The collapsible sidebar (spec §4.1): a section picker above whichever
/// section is showing. Only one section is visible at a time.
///
/// Built with AppKit tables rather than SwiftUI lists: a click and Return
/// must jump (and add a history entry) while the arrow keys only move the
/// selection, table rows are created lazily for thumbnails, and both are
/// testable without rendering.
public final class SidebarViewController: NSViewController {
    public private(set) var sections: [SidebarSectionViewController]
    public private(set) var visibleSection: SidebarSection
    /// Sections the picker leaves out, such as search results while no
    /// search is running.
    public private(set) var hiddenSections: Set<SidebarSection> = []
    /// Called when the user picks another section.
    public var onSectionChange: ((SidebarSection) -> Void)?

    public let picker = NSSegmentedControl()
    private let container = NSView()

    public init(sections: [SidebarSectionViewController], visible: SidebarSection) {
        self.sections = sections
        visibleSection = sections.contains { $0.section == visible } ? visible : (sections.first?.section ?? visible)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func loadView() {
        let root = NSView()
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.group)
        root.setAccessibilityLabel("Sidebar")
        picker.segmentStyle = .automatic
        picker.trackingMode = .selectOne
        picker.target = self
        picker.action = #selector(pickerChanged(_:))
        picker.setAccessibilityLabel("Sidebar section")
        picker.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(picker)
        root.addSubview(container)
        NSLayoutConstraint.activate([
            picker.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 8),
            picker.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            picker.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 8),
            container.topAnchor.constraint(equalTo: picker.bottomAnchor, constant: 8),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        rebuildPicker()
        showVisibleSection()
    }

    /// The sections the picker offers, in order.
    public var availableSections: [SidebarSection] {
        sections.map(\.section).filter { !hiddenSections.contains($0) }
    }

    public func controller(for section: SidebarSection) -> SidebarSectionViewController? {
        sections.first { $0.section == section }
    }

    /// Shows `section`, if it is available.
    public func show(_ section: SidebarSection) {
        guard availableSections.contains(section) else { return }
        visibleSection = section
        guard isViewLoaded else { return }
        rebuildPicker()
        showVisibleSection()
    }

    public func setHidden(_ hidden: Bool, for section: SidebarSection) {
        if hidden { hiddenSections.insert(section) } else { hiddenSections.remove(section) }
        if hidden, visibleSection == section, let fallback = availableSections.first {
            visibleSection = fallback
            if isViewLoaded { showVisibleSection() }
        }
        if isViewLoaded { rebuildPicker() }
    }

    /// Moves keyboard focus into the visible section.
    public func focusVisibleSection() {
        guard let target = controller(for: visibleSection)?.preferredFirstResponder else { return }
        view.window?.makeFirstResponder(target)
    }

    private func rebuildPicker() {
        let available = availableSections
        picker.segmentCount = available.count
        for (index, section) in available.enumerated() {
            let image = NSImage(systemSymbolName: section.symbolName, accessibilityDescription: section.title)
            picker.setImage(image, forSegment: index)
            picker.setToolTip(section.title, forSegment: index)
            picker.setWidth(36, forSegment: index)
        }
        picker.selectedSegment = available.firstIndex(of: visibleSection) ?? -1
    }

    private func showVisibleSection() {
        guard let controller = controller(for: visibleSection) else { return }
        for child in children where child !== controller {
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        guard controller.parent !== self else { return }
        addChild(controller)
        let content = controller.view
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    @objc private func pickerChanged(_ sender: NSSegmentedControl) {
        let available = availableSections
        guard available.indices.contains(sender.selectedSegment) else { return }
        let section = available[sender.selectedSegment]
        guard section != visibleSection else { return }
        show(section)
        onSectionChange?(section)
    }
}

// MARK: Shared pieces

/// A table that activates the selected row on Return or Enter, like a click,
/// while the arrow keys only move the selection.
public final class ActivatingTableView: NSTableView {
    var onActivate: ((Int) -> Void)?

    public override func keyDown(with event: NSEvent) {
        if Self.isActivationKey(event), selectedRow >= 0 {
            onActivate?(selectedRow)
        } else {
            super.keyDown(with: event)
        }
    }

    static func isActivationKey(_ event: NSEvent) -> Bool {
        event.keyCode == 36 || event.keyCode == 76
    }
}

public final class ActivatingOutlineView: NSOutlineView {
    var onActivate: ((Int) -> Void)?

    public override func keyDown(with event: NSEvent) {
        if ActivatingTableView.isActivationKey(event), selectedRow >= 0 {
            onActivate?(selectedRow)
        } else {
            super.keyDown(with: event)
        }
    }
}

extension NSScrollView {
    static func sidebarScrollView(for documentView: NSView) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        return scrollView
    }
}

extension NSView {
    func pinEdges(of child: NSView, insets: NSEdgeInsets = NSEdgeInsetsZero) {
        child.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            child.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            child.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
            child.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom),
        ])
    }
}

/// A centred, wrapping, secondary-coloured message for empty states.
func emptyStateLabel(_ text: String) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.alignment = .center
    label.textColor = .secondaryLabelColor
    label.font = .preferredFont(forTextStyle: .callout)
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
}

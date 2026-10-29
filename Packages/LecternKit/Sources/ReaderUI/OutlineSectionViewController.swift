import AppKit
import PDFKit
import ReaderCore

/// The document's outline (table of contents), expandable, with keyboard
/// navigation: the arrow keys move and expand or collapse, Return or a click
/// jumps. A document without an outline says so.
public final class OutlineSectionViewController: SidebarSectionViewController {
    /// Called when an entry is clicked or activated with Return.
    public var onJump: ((PDFOutline) -> Void)?

    public private(set) var root: PDFOutline?
    public let outlineView = ActivatingOutlineView()
    public let emptyLabel = emptyStateLabel("This document has no table of contents.")
    private var scrollView: NSScrollView?

    public init() {
        super.init(section: .outline)
    }

    public override func loadView() {
        let root = NSView()
        let column = NSTableColumn(identifier: .init("title"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.rowSizeStyle = .default
        outlineView.usesAutomaticRowHeights = true
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(clicked(_:))
        outlineView.onActivate = { [weak self] row in self?.activate(row: row) }
        outlineView.setAccessibilityLabel("Table of contents")
        let scrollView = NSScrollView.sidebarScrollView(for: outlineView)
        self.scrollView = scrollView
        root.addSubview(scrollView)
        root.pinEdges(of: scrollView)
        root.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            emptyLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
        ])
        view = root
        reload()
    }

    public override var preferredFirstResponder: NSView? { hasOutline ? outlineView : nil }

    /// Shows `document`'s outline.
    public func setDocument(_ document: PDFDocument?) {
        root = document?.outlineRoot
        if isViewLoaded { reload() }
    }

    public var hasOutline: Bool { (root?.numberOfChildren ?? 0) > 0 }

    private func reload() {
        outlineView.reloadData()
        expandOpenItems(under: root)
        scrollView?.isHidden = !hasOutline
        emptyLabel.isHidden = hasOutline
    }

    /// Entries the document marks as open start expanded.
    private func expandOpenItems(under parent: PDFOutline?) {
        guard let parent else { return }
        for index in 0..<parent.numberOfChildren {
            guard let child = parent.child(at: index), child.numberOfChildren > 0, child.isOpen else { continue }
            outlineView.expandItem(child)
            expandOpenItems(under: child)
        }
    }

    @objc private func clicked(_ sender: Any?) {
        // A click on the disclosure triangle only expands.
        guard outlineView.clickedRow >= 0 else { return }
        activate(row: outlineView.clickedRow)
    }

    public func activate(row: Int) {
        guard let item = outlineView.item(atRow: row) as? PDFOutline else { return }
        onJump?(item)
    }
}

extension OutlineSectionViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        ((item as? PDFOutline) ?? root)?.numberOfChildren ?? 0
    }

    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? PDFOutline) ?? root)?.child(at: index) as Any
    }

    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        ((item as? PDFOutline)?.numberOfChildren ?? 0) > 0
    }

    public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("OutlineCell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            // Long titles end in "…" at the sidebar's edge instead of widening the column.
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                label.topAnchor.constraint(equalTo: cell.topAnchor, constant: 3),
                label.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -3),
            ])
            return cell
        }()
        let title = (item as? PDFOutline)?.label ?? ""
        cell.textField?.stringValue = title.isEmpty ? "Untitled" : title
        // The full title, for when it's cut short.
        cell.toolTip = title.isEmpty ? nil : title
        cell.textField?.toolTip = cell.toolTip
        return cell
    }
}

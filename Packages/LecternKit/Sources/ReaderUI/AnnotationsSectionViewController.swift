import AppKit
import ReaderCore

/// One annotation in the sidebar list.
public struct AnnotationListItem: Equatable {
    /// Identifies the annotation for the window; stable while it exists.
    public let id: ObjectIdentifier
    public let pageIndex: Int
    public let pageLabel: String
    /// "Highlight", "Note", "Strike Through"…
    public let kind: String
    /// "Yellow", or a hue name for another app's colour.
    public let colorName: String
    /// The marked-up words, or empty.
    public let excerpt: String
    /// The note or comment, or empty.
    public let comment: String

    public init(id: ObjectIdentifier, pageIndex: Int, pageLabel: String, kind: String, colorName: String, excerpt: String, comment: String) {
        self.id = id
        self.pageIndex = pageIndex
        self.pageLabel = pageLabel
        self.kind = kind
        self.colorName = colorName
        self.excerpt = excerpt
        self.comment = comment
    }

    /// What VoiceOver reads for the row.
    public var accessibilityLabel: String {
        var text = "\(kind), \(colorName), page \(pageLabel)"
        if !excerpt.isEmpty { text += ": \(excerpt)" }
        if !comment.isEmpty { text += ". \(kind == "Note" ? "Note" : "Comment"): \(comment)" }
        return text
    }
}

/// The annotation list (spec §5.3): every annotation grouped by page, with its kind, colour name,
/// the words it marks and its comment. Clicking a row or pressing Return jumps to it.
public final class AnnotationsSectionViewController: SidebarSectionViewController {
    /// Called with the annotation to jump to.
    public var onSelect: ((AnnotationListItem) -> Void)?

    public private(set) var items: [AnnotationListItem] = []
    /// Page headers and items, in display order.
    private enum Row {
        case page(String)
        case item(Int)
    }

    private var rows: [Row] = []
    public let tableView = ActivatingTableView()
    private let emptyLabel = emptyStateLabel("No annotations.\nSelect text to highlight it, or choose Annotate ▸ Add Note.")

    public init() {
        super.init(section: .annotations)
    }

    public override func loadView() {
        let root = NSView()
        let column = NSTableColumn(identifier: .init("annotation"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.usesAutomaticRowHeights = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(clicked(_:))
        tableView.onActivate = { [weak self] row in self?.activate(row: row) }
        tableView.setAccessibilityLabel("Annotations")
        let scrollView = NSScrollView.sidebarScrollView(for: tableView)
        root.addSubview(scrollView)
        root.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            emptyLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
        ])
        view = root
        reload()
    }

    public override var preferredFirstResponder: NSView? { tableView }

    /// Replaces the list, keeping the selection on the same annotation if it is still there.
    public func setItems(_ items: [AnnotationListItem]) {
        let selected = selectedItem?.id
        self.items = items
        rows = []
        var lastPage: Int?
        for (index, item) in items.enumerated() {
            if item.pageIndex != lastPage {
                rows.append(.page("Page \(item.pageLabel)"))
                lastPage = item.pageIndex
            }
            rows.append(.item(index))
        }
        reload()
        if let selected { select(selected) }
    }

    public var selectedItem: AnnotationListItem? {
        guard isViewLoaded, tableView.selectedRow >= 0, case .item(let index)? = rows[safe: tableView.selectedRow] else { return nil }
        return items[index]
    }

    /// Marks the annotation shown in the reading area, without jumping.
    public func select(_ id: ObjectIdentifier?) {
        guard isViewLoaded else { return }
        guard let id, let row = rows.firstIndex(where: { if case .item(let i) = $0 { items[i].id == id } else { false } }) else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    /// Jumps to the item at `index` in `items`, as a click on its row does.
    public func activate(itemAt index: Int) {
        guard items.indices.contains(index) else { return }
        onSelect?(items[index])
    }

    private func reload() {
        guard isViewLoaded else { return }
        tableView.reloadData()
        emptyLabel.isHidden = !items.isEmpty
    }

    private func activate(row: Int) {
        guard case .item(let index)? = rows[safe: row] else { return }
        onSelect?(items[index])
    }

    @objc private func clicked(_ sender: Any?) {
        guard tableView.clickedRow >= 0 else { return }
        activate(row: tableView.clickedRow)
    }
}

extension AnnotationsSectionViewController: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    public func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .page? = rows[safe: row] { return true }
        return false
    }

    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .item? = rows[safe: row] { return true }
        return false
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[safe: row] {
        case .page(let title)?:
            let label = NSTextField(labelWithString: title)
            label.font = .preferredFont(forTextStyle: .caption1)
            label.textColor = .secondaryLabelColor
            return label
        case .item(let index)?:
            let identifier = NSUserInterfaceItemIdentifier("AnnotationCell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? AnnotationCellView ?? {
                let cell = AnnotationCellView()
                cell.identifier = identifier
                return cell
            }()
            cell.show(items[index])
            return cell
        case nil:
            return nil
        }
    }
}

final class AnnotationCellView: NSTableCellView {
    private let kindLabel = NSTextField(labelWithString: "")
    private let excerptLabel = NSTextField(wrappingLabelWithString: "")
    private let commentLabel = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        kindLabel.font = .preferredFont(forTextStyle: .caption1)
        kindLabel.textColor = .secondaryLabelColor
        kindLabel.lineBreakMode = .byTruncatingTail
        for label in [kindLabel, excerptLabel, commentLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        excerptLabel.maximumNumberOfLines = 2
        excerptLabel.lineBreakMode = .byTruncatingTail
        excerptLabel.font = .preferredFont(forTextStyle: .callout)
        commentLabel.maximumNumberOfLines = 3
        commentLabel.lineBreakMode = .byTruncatingTail
        commentLabel.font = .preferredFont(forTextStyle: .callout)
        commentLabel.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [kindLabel, excerptLabel, commentLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        addSubview(stack)
        pinEdges(of: stack, insets: NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4))
        excerptLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        commentLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ item: AnnotationListItem) {
        kindLabel.stringValue = "\(item.kind) · \(item.colorName)"
        excerptLabel.stringValue = item.excerpt.isEmpty ? "" : "“\(item.excerpt)”"
        excerptLabel.isHidden = item.excerpt.isEmpty
        commentLabel.stringValue = item.comment
        commentLabel.isHidden = item.comment.isEmpty
        setAccessibilityLabel(item.accessibilityLabel)
        // The whole excerpt and comment, for when they're cut short.
        toolTip = [item.excerpt, item.comment].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

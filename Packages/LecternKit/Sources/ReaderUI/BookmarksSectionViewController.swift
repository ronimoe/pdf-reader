import AppKit
import ReaderCore

/// One bookmark in the sidebar list.
public struct BookmarkListItem: Equatable {
    public let id: UUID
    public let name: String
    public let pageLabel: String

    public init(id: UUID, name: String, pageLabel: String) {
        self.id = id
        self.name = name
        self.pageLabel = pageLabel
    }

    /// What VoiceOver reads for the row.
    public var accessibilityLabel: String { "\(name), page \(pageLabel)" }
}

/// The reader's bookmarks (A2, spec §4.1), in reading order. A click or Return jumps (and adds a
/// history entry, B2); ⌫ removes the selected bookmark; the context menu renames or removes it.
public final class BookmarksSectionViewController: SidebarSectionViewController {
    public var onSelect: ((UUID) -> Void)?
    public var onRename: ((UUID) -> Void)?
    public var onRemove: ((UUID) -> Void)?

    public private(set) var items: [BookmarkListItem] = []
    public let tableView = ActivatingTableView()
    private let emptyLabel = emptyStateLabel("No bookmarks.\nChoose Bookmarks ▸ Add Bookmark (⌘D) to mark the page you’re reading.")

    public init() {
        super.init(section: .bookmarks)
    }

    public override func loadView() {
        let root = NSView()
        let column = NSTableColumn(identifier: .init("bookmark"))
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
        tableView.onDelete = { [weak self] row in
            guard let self, items.indices.contains(row) else { return }
            onRemove?(items[row].id)
        }
        tableView.setAccessibilityLabel("Bookmarks")
        let menu = NSMenu(title: "Bookmark")
        menu.delegate = self
        tableView.menu = menu
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

    /// Replaces the list, keeping the selection on the same bookmark if it is still there.
    public func setItems(_ items: [BookmarkListItem]) {
        let selected = selectedItem?.id
        self.items = items
        reload()
        if let selected, let row = items.firstIndex(where: { $0.id == selected }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    public var selectedItem: BookmarkListItem? {
        guard isViewLoaded, items.indices.contains(tableView.selectedRow) else { return nil }
        return items[tableView.selectedRow]
    }

    /// Jumps to the item at `index`, as a click on its row does.
    public func activate(itemAt index: Int) {
        activate(row: index)
    }

    private func reload() {
        guard isViewLoaded else { return }
        tableView.reloadData()
        emptyLabel.isHidden = !items.isEmpty
    }

    private func activate(row: Int) {
        guard items.indices.contains(row) else { return }
        onSelect?(items[row].id)
    }

    @objc private func clicked(_ sender: Any?) {
        guard tableView.clickedRow >= 0 else { return }
        activate(row: tableView.clickedRow)
    }

    @objc private func renameClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onRename?(id)
    }

    @objc private func removeClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onRemove?(id)
    }
}

extension BookmarksSectionViewController: NSMenuDelegate {
    /// The row that was right-clicked: Rename… and Remove.
    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard items.indices.contains(row) else { return }
        let id = items[row].id
        let rename = menu.addItem(withTitle: "Rename Bookmark…", action: #selector(renameClicked(_:)), keyEquivalent: "")
        rename.target = self
        rename.representedObject = id
        let remove = menu.addItem(withTitle: "Remove Bookmark", action: #selector(removeClicked(_:)), keyEquivalent: "")
        remove.target = self
        remove.representedObject = id
    }
}

extension BookmarksSectionViewController: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("BookmarkCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? BookmarkCellView ?? {
            let cell = BookmarkCellView()
            cell.identifier = identifier
            return cell
        }()
        cell.show(items[row])
        return cell
    }
}

final class BookmarkCellView: NSTableCellView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let pageLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        let icon = NSImageView(image: NSImage(systemSymbolName: "bookmark.fill", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.setAccessibilityElement(false)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.font = .preferredFont(forTextStyle: .body)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pageLabel.font = .preferredFont(forTextStyle: .caption1)
        pageLabel.textColor = .secondaryLabelColor
        pageLabel.setContentHuggingPriority(.required, for: .horizontal)
        let stack = NSStackView(views: [icon, nameLabel, pageLabel])
        stack.orientation = .horizontal
        stack.spacing = 6
        addSubview(stack)
        pinEdges(of: stack, insets: NSEdgeInsets(top: 3, left: 4, bottom: 3, right: 6))
        textField = nameLabel
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ item: BookmarkListItem) {
        nameLabel.stringValue = item.name
        pageLabel.stringValue = item.pageLabel
        setAccessibilityLabel(item.accessibilityLabel)
    }
}

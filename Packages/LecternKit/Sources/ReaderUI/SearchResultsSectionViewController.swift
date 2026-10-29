import AppKit
import ReaderCore
import ReaderKit

/// Search results (B8): the status line with a count and progress, a note
/// for partly scanned documents, and one row per match with the text around
/// it. Clicking a row or pressing Return shows that match.
public final class SearchResultsSectionViewController: SidebarSectionViewController {
    /// Called with the index of the result to show.
    public var onShowResult: ((Int) -> Void)?

    public private(set) var search: DocumentSearch?
    private var numbering = PageNumbering(pageCount: 0)

    public let statusLabel = NSTextField(labelWithString: "")
    public let noteLabel = NSTextField(wrappingLabelWithString: "")
    public let progress = NSProgressIndicator()
    public let tableView = ActivatingTableView()
    /// Rows shown; the table never grows past this many, so a search for a
    /// common word stays responsive. The count still says how many there are.
    public static let rowLimit = 5000

    public init() {
        super.init(section: .search)
    }

    public override func loadView() {
        let root = NSView()
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setAccessibilityLabel("Search status")
        noteLabel.font = .preferredFont(forTextStyle: .caption1)
        noteLabel.textColor = .secondaryLabelColor
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.controlSize = .small
        progress.setAccessibilityLabel("Search progress")

        let column = NSTableColumn(identifier: .init("result"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.usesAutomaticRowHeights = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(clicked(_:))
        tableView.onActivate = { [weak self] row in self?.onShowResult?(row) }
        tableView.setAccessibilityLabel("Search results")
        let scrollView = NSScrollView.sidebarScrollView(for: tableView)

        let header = NSStackView(views: [statusLabel, progress, noteLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 4
        header.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)
        root.addSubview(scrollView)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 4),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            progress.widthAnchor.constraint(equalTo: header.widthAnchor),
            noteLabel.widthAnchor.constraint(equalTo: header.widthAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        reload()
    }

    public override var preferredFirstResponder: NSView? { tableView }

    public func setSearch(_ search: DocumentSearch?, numbering: PageNumbering) {
        self.search = search
        self.numbering = numbering
        if isViewLoaded { reload() }
    }

    /// Picks up new results and progress.
    public func reload() {
        guard isViewLoaded else { return }
        let summary = search?.summary
        statusLabel.stringValue = summary?.status ?? ""
        let note = summary?.textCoverageNote
        noteLabel.stringValue = note ?? ""
        noteLabel.isHidden = note == nil
        progress.isHidden = !(search?.isSearching ?? false)
        progress.doubleValue = search?.progress ?? 0
        let selected = tableView.selectedRow
        tableView.reloadData()
        if selected >= 0, selected < tableView.numberOfRows {
            tableView.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
        }
    }

    /// Marks `index` as the result being shown.
    public func selectResult(_ index: Int) {
        guard isViewLoaded, index >= 0, index < tableView.numberOfRows else { return }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
    }

    @objc private func clicked(_ sender: Any?) {
        guard tableView.clickedRow >= 0 else { return }
        onShowResult?(tableView.clickedRow)
    }
}

extension SearchResultsSectionViewController: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        min(search?.results.count ?? 0, Self.rowLimit)
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let result = search?.results[safe: row] else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("ResultCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? SearchResultCellView ?? {
            let cell = SearchResultCellView()
            cell.identifier = identifier
            return cell
        }()
        let page = "Page \(numbering.label(forPageAt: result.pageIndex))"
        let excerpt = result.excerpt
        cell.show(page: page, excerpt: excerpt.text, match: excerpt.match)
        cell.setAccessibilityLabel("\(page): \(excerpt.text)")
        return cell
    }
}

final class SearchResultCellView: NSTableCellView {
    private let pageLabel = NSTextField(labelWithString: "")
    private let excerptLabel = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        pageLabel.font = .preferredFont(forTextStyle: .caption1)
        pageLabel.textColor = .secondaryLabelColor
        excerptLabel.maximumNumberOfLines = 3
        excerptLabel.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [pageLabel, excerptLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        addSubview(stack)
        pinEdges(of: stack, insets: NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4))
        excerptLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(page: String, excerpt: String, match: NSRange) {
        pageLabel.stringValue = page
        let font = NSFont.preferredFont(forTextStyle: .callout)
        let text = NSMutableAttributedString(string: excerpt, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        if NSMaxRange(match) <= text.length {
            text.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: font.pointSize), range: match)
        }
        excerptLabel.attributedStringValue = text
    }

    var excerptText: String { excerptLabel.stringValue }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

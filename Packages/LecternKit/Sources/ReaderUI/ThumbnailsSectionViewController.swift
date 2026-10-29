import AppKit
import PDFKit
import ReaderCore
import ReaderKit

/// Page thumbnails. They are drawn lazily by a `PageRenderer` on its own
/// actor, only for rows the table actually shows, so scrolling the reader
/// never waits on them. The current page is the selected row.
public final class ThumbnailsSectionViewController: SidebarSectionViewController {
    /// Called when a thumbnail is clicked or activated with Return.
    public var onJump: ((Int) -> Void)?

    public let tableView = ActivatingTableView()
    public private(set) var document: PDFDocument?
    public private(set) var renderer: PageRenderer?
    /// A page's label, asked for only for rows on screen.
    private var labelForPage: (Int) -> String = { String($0 + 1) }
    private var rotation = 0
    /// Set while the table's selection follows the reader, so it isn't
    /// mistaken for the user's.
    private var isFollowingReader = false

    /// The thumbnail's longer side, in points.
    static let thumbnailSide: CGFloat = 120
    static let labelHeight: CGFloat = 18
    static let verticalPadding: CGFloat = 10

    public init() {
        super.init(section: .thumbnails)
    }

    public override func loadView() {
        let root = NSView()
        let column = NSTableColumn(identifier: .init("page"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        // One fixed height: variable heights would make the table measure
        // every page of a long document when it loads.
        tableView.rowHeight = Self.thumbnailSide + Self.labelHeight + Self.verticalPadding
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(clicked(_:))
        tableView.onActivate = { [weak self] row in self?.onJump?(row) }
        tableView.setAccessibilityLabel("Page thumbnails")
        let scrollView = NSScrollView.sidebarScrollView(for: tableView)
        root.addSubview(scrollView)
        root.pinEdges(of: scrollView)
        view = root
    }

    public override var preferredFirstResponder: NSView? { tableView }

    /// Shows `document`'s pages, drawn by `renderer`, labelled by `label`.
    public func configure(document: PDFDocument?, renderer: PageRenderer?, label: @escaping (Int) -> String, rotation: Int) {
        self.document = document
        self.renderer = renderer
        labelForPage = label
        self.rotation = rotation
        loadViewIfNeeded()
        tableView.reloadData()
    }

    /// Re-draws after a view rotation (B9).
    public func setRotation(_ rotation: Int) {
        guard rotation != self.rotation else { return }
        self.rotation = rotation
        tableView.reloadData()
    }

    /// Highlights `index` as the current page and scrolls it into view,
    /// without jumping.
    public func setCurrentPage(_ index: Int) {
        guard isViewLoaded, index >= 0, index < tableView.numberOfRows else { return }
        guard tableView.selectedRow != index else { return }
        isFollowingReader = true
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
        isFollowingReader = false
    }

    public var currentPage: Int? { tableView.selectedRow >= 0 ? tableView.selectedRow : nil }

    @objc private func clicked(_ sender: Any?) {
        guard tableView.clickedRow >= 0 else { return }
        onJump?(tableView.clickedRow)
    }

    /// The thumbnail's size in points for a page: the longer side is fixed,
    /// the aspect follows the page as it is shown (rotation included).
    func thumbnailSize(forPageAt index: Int) -> CGSize {
        guard let page = document?.page(at: index) else { return CGSize(width: 90, height: Self.thumbnailSide) }
        var bounds = page.bounds(for: .cropBox).size
        if ViewSettings.normalized(page.rotation) % 180 != 0 { bounds = CGSize(width: bounds.height, height: bounds.width) }
        guard bounds.width > 0, bounds.height > 0 else { return CGSize(width: 90, height: Self.thumbnailSide) }
        let scale = Self.thumbnailSide / max(bounds.width, bounds.height)
        return CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
    }
}

extension ThumbnailsSectionViewController: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        document?.pageCount ?? 0
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("ThumbnailCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? ThumbnailCellView ?? {
            let cell = ThumbnailCellView()
            cell.identifier = identifier
            return cell
        }()
        let size = thumbnailSize(forPageAt: row)
        let label = labelForPage(row)
        let count = document?.pageCount ?? 0
        cell.show(pageIndex: row, label: label, size: size)
        cell.setAccessibilityLabel(label == String(row + 1) ? "Page \(row + 1) of \(count)" : "Page \(label) (\(row + 1) of \(count))")
        if let renderer {
            let scale = tableView.window?.backingScaleFactor ?? 2
            let rotation = rotation
            cell.load {
                await renderer.thumbnail(pageIndex: row, fitting: size, scale: scale, rotation: rotation)
            }
        }
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        // Selection alone never jumps: a click or Return does.
    }
}

/// One thumbnail: the page image above its label.
final class ThumbnailCellView: NSTableCellView {
    private let pageImageView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var widthConstraint: NSLayoutConstraint?
    private var heightConstraint: NSLayoutConstraint?
    private var task: Task<Void, Never>?
    private(set) var pageIndex = -1

    var image: NSImage? { pageImageView.image }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        pageImageView.layer?.borderColor = resolvedCGColor(.separatorColor)
    }

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        pageImageView.imageScaling = .scaleProportionallyUpOrDown
        pageImageView.wantsLayer = true
        // White in dark mode too: the page is the document's, not the app's (spec §4.2).
        pageImageView.layer?.backgroundColor = NSColor.white.cgColor
        pageImageView.layer?.borderColor = resolvedCGColor(.separatorColor)
        pageImageView.layer?.borderWidth = 1
        pageImageView.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pageImageView)
        addSubview(label)
        let width = pageImageView.widthAnchor.constraint(equalToConstant: 90)
        let height = pageImageView.heightAnchor.constraint(equalToConstant: 120)
        widthConstraint = width
        heightConstraint = height
        NSLayoutConstraint.activate([
            width, height,
            pageImageView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            pageImageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.topAnchor.constraint(equalTo: pageImageView.bottomAnchor, constant: 2),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(pageIndex: Int, label text: String, size: CGSize) {
        task?.cancel()
        task = nil
        self.pageIndex = pageIndex
        pageImageView.image = nil
        widthConstraint?.constant = size.width
        heightConstraint?.constant = size.height
        label.stringValue = text
    }

    /// Starts drawing the thumbnail; a reused cell cancels the old request.
    func load(_ render: @escaping @Sendable () async -> CGImage?) {
        let index = pageIndex
        let size = NSSize(width: widthConstraint?.constant ?? 90, height: heightConstraint?.constant ?? 120)
        task = Task { [weak self] in
            let image = await render()
            guard !Task.isCancelled, let image, let self, self.pageIndex == index else { return }
            self.pageImageView.image = NSImage(cgImage: image, size: size)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        task?.cancel()
        task = nil
        pageImageView.image = nil
    }

    /// Waits for the thumbnail in progress, for tests.
    func waitForImage() async {
        await task?.value
    }
}

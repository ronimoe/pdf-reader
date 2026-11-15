import AppKit
import ReaderCore

/// A citation preview's content: the cited work as its reference-list entry describes it, one
/// field a row. A field the entry doesn't give says so; a reference list never gives a work's
/// keywords or abstract, and nothing is looked up elsewhere (Rule 6).
public final class CitationCardView: NSView {
    public enum Field: String, CaseIterable, Sendable {
        case title = "Title"
        case author = "Author"
        case url = "URL"
        case series = "Series"
        case year = "Year"
        case keywords = "Keywords"
        case abstract = "Abstract"
    }

    /// What a field the entry doesn't give shows.
    public static let missing = "Not in the reference"

    public let work: CitedWork
    /// The text each field shows, in order.
    public private(set) var values: [Field: String] = [:]
    /// The view showing each field's value.
    public private(set) var valueViews: [Field: NSView] = [:]
    /// The URL, as a link; clicking it calls `onOpenURL`. Nil without one.
    public private(set) var urlButton: NSButton?
    /// Called when the URL is clicked: it opens only through the link policy (A4).
    public var onOpenURL: ((URL) -> Void)?

    /// A card `width` points wide; its height follows from what it shows.
    public init(work: CitedWork, width: CGFloat) {
        self.work = work
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        let labelWidth: CGFloat = 70
        let valueWidth = width - labelWidth - 10
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 6
        grid.columnSpacing = 10
        grid.translatesAutoresizingMaskIntoConstraints = false

        let year = work.year.map(String.init)
        let texts: [Field: String?] = [
            .title: work.title, .author: work.authors, .url: work.url?.absoluteString,
            .series: work.series, .year: year, .keywords: nil, .abstract: nil,
        ]
        for field in Field.allCases {
            let text = texts[field] ?? nil
            values[field] = text ?? Self.missing
            let label = NSTextField(labelWithString: field.rawValue + ":")
            label.font = .preferredFont(forTextStyle: .body)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            // VoiceOver reads the field's name with its value instead.
            label.setAccessibilityElement(false)
            let value: NSView
            if field == .url, let url = work.url {
                value = link(to: url, width: valueWidth)
            } else {
                value = Self.value(text, of: field, width: valueWidth)
            }
            valueViews[field] = value
            let row = grid.addRow(with: [label, value])
            row.rowAlignment = .firstBaseline
        }
        grid.column(at: 0).width = labelWidth
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = valueWidth

        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: width),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Cited work")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// A field's value, wrapped and selectable so it can be copied; the title in bold.
    private static func value(_ text: String?, of field: Field, width: CGFloat) -> NSTextField {
        let value = NSTextField(wrappingLabelWithString: text ?? missing)
        value.isSelectable = text != nil
        value.preferredMaxLayoutWidth = width
        value.font = field == .title ? .boldSystemFont(ofSize: NSFont.systemFontSize) : .preferredFont(forTextStyle: .body)
        value.textColor = text == nil ? .secondaryLabelColor : .labelColor
        // A long author list or title wraps to a few lines, the last cut short; the whole text
        // is in the tooltip. (A truncating line break mode would make it a single line.)
        value.maximumNumberOfLines = field == .title ? 4 : 3
        value.cell?.truncatesLastVisibleLine = true
        if let text { value.toolTip = text }
        value.setAccessibilityLabel(field.rawValue)
        return value
    }

    /// The URL as a link-coloured button, shortened in the middle if long; the full URL is in
    /// its tooltip and accessible name.
    private func link(to url: URL, width: CGFloat) -> NSButton {
        let button = NSButton(title: url.absoluteString, target: self, action: #selector(openURL(_:)))
        button.isBordered = false
        button.bezelStyle = .inline
        button.alignment = .left
        button.contentTintColor = .linkColor
        button.font = .preferredFont(forTextStyle: .body)
        button.lineBreakMode = .byTruncatingMiddle
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.widthAnchor.constraint(lessThanOrEqualToConstant: width).isActive = true
        button.toolTip = url.absoluteString
        button.setAccessibilityLabel("Url: \(url.absoluteString)")
        urlButton = button
        return button
    }

    @objc func openURL(_ sender: Any?) {
        guard let url = work.url else { return }
        onOpenURL?(url)
    }
}

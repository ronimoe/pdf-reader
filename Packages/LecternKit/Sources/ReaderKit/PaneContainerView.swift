import AppKit
import PDFKit

/// Holds one pane's reading view with its chrome: the focus indicator and
/// close button shown while the tab is split (B3), and the status line that
/// shows a link's full URL on hover or keyboard focus (A4, Rule 8).
public final class PaneContainerView: NSView {
    public let pdfView: ReaderPDFView
    /// A bar along the top of the focused pane. Shape as well as colour: the
    /// other pane has none (Rule 8).
    public let focusBar = NSView()
    public let closeButton = NSButton()
    public let statusLine = LinkStatusLine()
    public var onClose: (() -> Void)?

    public init(pdfView: ReaderPDFView) {
        self.pdfView = pdfView
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        for view in [pdfView, focusBar, closeButton, statusLine] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        focusBar.wantsLayer = true
        focusBar.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        focusBar.isHidden = true
        focusBar.setAccessibilityElement(false)

        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close Pane")
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closePane(_:))
        closeButton.toolTip = "Close this pane"
        closeButton.setAccessibilityLabel("Close pane")
        closeButton.isHidden = true

        NSLayoutConstraint.activate([
            pdfView.topAnchor.constraint(equalTo: topAnchor),
            pdfView.leadingAnchor.constraint(equalTo: leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: trailingAnchor),
            pdfView.bottomAnchor.constraint(equalTo: bottomAnchor),
            focusBar.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            focusBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            focusBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            focusBar.heightAnchor.constraint(equalToConstant: 3),
            closeButton.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            statusLine.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            statusLine.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            statusLine.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Reading pane")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Split chrome: the focus bar on the focused pane and a close button on
    /// both. A single pane shows neither.
    public func setSplitChrome(isSplit: Bool, isFocused: Bool, name: String) {
        focusBar.isHidden = !(isSplit && isFocused)
        closeButton.isHidden = !isSplit
        setAccessibilityLabel(isSplit ? "\(name) pane" : "Reading pane")
        setAccessibilityValue(isSplit && isFocused ? "focused" : nil)
    }

    public var showsFocus: Bool { !focusBar.isHidden }

    @objc private func closePane(_ sender: Any?) {
        onClose?()
    }

    /// Shows where a link goes, or hides the line for nil.
    public func showLinkStatus(_ target: LinkTarget?) {
        statusLine.show(target.map(Self.statusText(for:)))
    }

    public static func statusText(for target: LinkTarget) -> String {
        switch target {
        case let .web(url), let .otherScheme(url):
            return url.absoluteString
        case let .destination(destination):
            guard let page = destination.page, let document = page.document else { return "Link in this document" }
            return "Page \(page.label ?? String(document.index(for: page) + 1)) — Space or Force Click to preview"
        case let .named(name):
            return "Viewer action: \(name.rawValue)"
        case let .blocked(type):
            return "Blocked: \(BlockedLink(actionType: type).title.lowercased())"
        }
    }
}

/// A small line at the bottom of the pane, as in a browser.
public final class LinkStatusLine: NSView {
    private let background = NSVisualEffectView()
    public let label = NSTextField(labelWithString: "")

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
        background.material = .toolTip
        background.blendingMode = .withinWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 6
        background.layer?.masksToBounds = true
        label.font = .preferredFont(forTextStyle: .caption1)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [background, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(background)
        background.addSubview(label)
        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: background.topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -3),
            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -8),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public var text: String? { isHidden ? nil : label.stringValue }

    public func show(_ text: String?) {
        guard let text else {
            isHidden = true
            return
        }
        label.stringValue = text
        label.toolTip = text
        setAccessibilityLabel(text)
        isHidden = false
    }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

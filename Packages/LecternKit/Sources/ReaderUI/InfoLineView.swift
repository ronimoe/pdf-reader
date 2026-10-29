import AppKit

/// A quiet, one-line note along the bottom of the reading area, with a close button: "This
/// document has form fields…" (A5). It never blocks reading and stays dismissed once closed.
public final class InfoLineView: NSView {
    public let label = NSTextField(labelWithString: "")
    public let closeButton = NSButton()
    /// Called after the user closes it.
    public var onDismiss: (() -> Void)?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
        let background = NSVisualEffectView()
        background.material = .headerView
        background.blendingMode = .withinWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        label.font = .preferredFont(forTextStyle: .callout)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        let icon = NSImageView(image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(dismiss(_:))
        closeButton.setAccessibilityLabel("Dismiss")
        let stack = NSStackView(views: [icon, label, closeButton])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 6)
        addSubview(background)
        background.addSubview(stack)
        for view in [background, stack] { view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public private(set) var isDismissed = false

    public var message: String? { isHidden ? nil : label.stringValue }

    /// Shows `message`, unless the user already closed this line.
    public func show(_ message: String) {
        guard !isDismissed else { return }
        label.stringValue = message
        setAccessibilityLabel(message)
        isHidden = false
    }

    @objc public func dismiss(_ sender: Any?) {
        isDismissed = true
        isHidden = true
        onDismiss?()
    }
}

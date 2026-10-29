import AppKit

/// The small popover for a note's text or a comment on markup (B4). Done (⌘Return) keeps the
/// text, Escape keeps the old one. Closing the popover by clicking elsewhere also keeps the text,
/// so nothing typed is lost (Rule 7).
public final class AnnotationTextEditorController: NSViewController {
    public let heading: String
    public let initialText: String
    /// Called once, with the text to keep, or nil when the edit was cancelled.
    public var onFinish: ((String?) -> Void)?

    public let textView = NSTextView()
    public let scrollView = NSScrollView()
    private var finished = false

    /// The popover's width: wide enough for a comfortable line of text.
    public static let width: CGFloat = 300
    /// About five lines of text show before it scrolls.
    public static let visibleLines = 5

    public init(heading: String, text: String) {
        self.heading = heading
        self.initialText = text
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 200))
        let title = NSTextField(labelWithString: heading)
        title.font = .preferredFont(forTextStyle: .headline)
        let font = NSFont.preferredFont(forTextStyle: .body)
        textView.string = initialText
        textView.font = font
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.setAccessibilityLabel(heading)
        textView.textContainerInset = NSSize(width: 2, height: 4)
        let scroll = scrollView
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        // A text view that wraps at the scroll view's width and grows downwards, so long text
        // scrolls and is never cut off.
        let contentWidth = Self.width - 24 - 4
        textView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: 0)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.containerSize = NSSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        let textHeight = (lineHeight * CGFloat(Self.visibleLines) + textView.textContainerInset.height * 2 + 4).rounded(.up)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let done = NSButton(title: "Done", target: self, action: #selector(done(_:)))
        done.keyEquivalent = "\r"
        done.keyEquivalentModifierMask = .command
        done.bezelStyle = .push
        let buttons = NSStackView(views: [NSView(), cancel, done])
        buttons.orientation = .horizontal
        for view in [title, scroll, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.heightAnchor.constraint(equalToConstant: textHeight),
            root.widthAnchor.constraint(equalToConstant: Self.width),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        view = root
        root.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: Self.width, height: root.fittingSize.height)
        root.setFrameSize(preferredContentSize)
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(textView)
    }

    /// The text as typed now.
    public var text: String { textView.string }

    @objc public func done(_ sender: Any?) { finish(text) }
    @objc public func cancel(_ sender: Any?) { finish(nil) }

    /// The popover closed some other way (a click elsewhere): keep what was typed.
    public func popoverDidClose() {
        finish(isViewLoaded ? text : nil)
    }

    private func finish(_ result: String?) {
        guard !finished else { return }
        finished = true
        onFinish?(result)
        presentingPopover?.performClose(nil)
    }

    /// Set by whoever shows the editor in a popover, so Done and Cancel can close it.
    public weak var presentingPopover: NSPopover?
}

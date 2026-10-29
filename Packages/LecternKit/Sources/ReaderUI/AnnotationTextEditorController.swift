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
    private var finished = false

    public init(heading: String, text: String) {
        self.heading = heading
        self.initialText = text
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 170))
        let title = NSTextField(labelWithString: heading)
        title.font = .preferredFont(forTextStyle: .headline)
        textView.string = initialText
        textView.font = .preferredFont(forTextStyle: .body)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.setAccessibilityLabel(heading)
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
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
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        view = root
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

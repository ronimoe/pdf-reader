import AppKit

/// A small, non-blocking notice over the top of the reading area: the brief
/// "Reloaded" after a file changed on disk (B7), or a lasting notice that
/// the file was removed. It never takes focus and lets clicks through.
public final class NoticeView: NSView {
    private let background = NSVisualEffectView()
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    public private(set) var message: String?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
        background.material = .hudWindow
        background.blendingMode = .withinWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        label.font = .preferredFont(forTextStyle: .callout)
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        addSubview(background)
        pinEdges(of: background)
        background.addSubview(label)
        background.pinEdges(of: label, insets: NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 14))
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `message`. A brief notice hides itself after `duration`; a
    /// lasting one stays until replaced or hidden.
    public func show(_ message: String, duration: TimeInterval? = 1.5) {
        hideWork?.cancel()
        self.message = message
        label.stringValue = message
        setAccessibilityLabel(message)
        isHidden = false
        alphaValue = 1
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue]
        )
        guard let duration else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.hide() }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    public func hide() {
        hideWork?.cancel()
        hideWork = nil
        message = nil
        isHidden = true
    }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

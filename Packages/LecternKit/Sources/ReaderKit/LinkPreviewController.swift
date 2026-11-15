import AppKit
import PDFKit
import ReaderCore

/// Shows a link preview's controller next to the link. Production uses a
/// popover; tests host the controller in an invisible window instead, as a
/// popover is a visible window of its own.
@MainActor
public protocol LinkPreviewPresenting: AnyObject {
    /// Shows `controller` pointing at `rect` in `view`'s coordinates. The
    /// presenter calls `controller.didClose()` once it is gone, however it
    /// was dismissed.
    func present(_ controller: LinkPreviewController, relativeTo rect: NSRect, of view: NSView)
    func dismiss(_ controller: LinkPreviewController)
}

/// Presents the preview in a transient `NSPopover`: clicking outside or
/// Escape dismisses it.
public final class PopoverPreviewPresenter: NSObject, LinkPreviewPresenting, NSPopoverDelegate {
    private var popover: NSPopover?
    private weak var controller: LinkPreviewController?
    /// Whether the popover fades in and out.
    public var animates = true

    public override init() {}

    public func present(_ controller: LinkPreviewController, relativeTo rect: NSRect, of view: NSView) {
        if let current = self.controller { dismiss(current) }
        let popover = Self.makePopover(animates: animates)
        popover.contentViewController = controller
        popover.delegate = self
        self.popover = popover
        self.controller = controller
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }

    public func dismiss(_ controller: LinkPreviewController) {
        guard controller === self.controller else { return }
        popover?.performClose(nil)
        // performClose can be refused while animating; close for certain.
        if popover?.isShown == true { popover?.close() }
    }

    /// A transient popover that doesn't animate while Reduce Motion is on.
    public static func makePopover(animates: Bool) -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = animates && !Motion.isReduced
        return popover
    }

    /// The popover itself, for a smoke test.
    public var currentPopover: NSPopover? { popover }

    public func popoverDidClose(_ notification: Notification) {
        let controller = self.controller
        popover = nil
        self.controller = nil
        controller?.didClose()
    }
}

/// A link preview (A3, Journey B): a second, view-only `ReaderPDFView` on
/// the same `PDFDocument`, scrolled to the destination with the target
/// marked. Links inside move the preview, with its own Back; the reader's
/// pane never moves unless the user chooses Go.
///
/// A citation's preview is a card describing the cited work instead
/// (`CitationCardView`), read from its entry in the reference list. Go and
/// Open in Split still lead to the entry.
public final class LinkPreviewController: NSViewController {
    public static let defaultSize = NSSize(width: 520, height: 380)
    /// A citation card's width; its height follows from what it shows.
    public static let citationWidth: CGFloat = 460

    public let previewView = ReaderPDFView(frame: NSRect(origin: .zero, size: LinkPreviewController.defaultSize))
    public private(set) var destination: PDFDestination
    /// Where the preview was before following links inside it.
    public private(set) var backStack: [PDFDestination] = []
    public let trigger: LinkPreviewRequest.Trigger
    private var linkText: String
    /// The cited work, for a citation: the preview is then a card, and
    /// `previewView` shows nothing.
    public let citation: CitedWork?
    public private(set) var citationCard: CitationCardView?

    /// Go: navigates the reader's pane and makes a history entry there.
    public var onGo: ((PDFDestination) -> Void)?
    public var onOpenInSplit: ((PDFDestination) -> Void)?
    /// Web, other-scheme and blocked links clicked inside the preview.
    public var onExternalLink: ((LinkTarget) -> Void)?
    /// Asks whoever presented the preview to dismiss it.
    public var onDismissRequest: (() -> Void)?
    /// Called once when the preview has gone.
    public var onClose: (() -> Void)?
    public private(set) var isClosed = false
    /// True once the pointer has been over the preview: a hover preview the
    /// user reached for stays open when the pointer leaves the link.
    public private(set) var pointerHasEntered = false

    public let titleLabel = NSTextField(labelWithString: "")
    public let backButton = NSButton()
    public let goButton = NSButton(title: "Go", target: nil, action: nil)
    public let splitButton = NSButton(title: "Open in Split", target: nil, action: nil)
    private var didShowDestination = false

    public init(
        document: PDFDocument, destination: PDFDestination, linkText: String = "", trigger: LinkPreviewRequest.Trigger = .keyboard,
        citation: CitedWork? = nil
    ) {
        self.destination = destination
        self.linkText = linkText
        self.trigger = trigger
        self.citation = citation
        super.init(nibName: nil, bundle: nil)
        if citation == nil { previewView.show(document) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func loadView() {
        if let citation {
            loadCitationView(citation)
            return
        }
        let root = PreviewRootView(frame: NSRect(origin: .zero, size: Self.defaultSize))
        root.onPointerEntered = { [weak self] in self?.pointerHasEntered = true }

        previewView.previewsOnHover = false
        previewView.contextMenuItems = { [] }
        previewView.onActivateLink = { [weak self] target in self?.follow(target) }
        previewView.onCancel = { [weak self] in
            self?.dismiss()
            return true
        }
        previewView.setAccessibilityLabel("Link preview")

        backButton.image = NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: "Back")
        backButton.bezelStyle = .accessoryBarAction
        backButton.isBordered = false
        backButton.target = self
        backButton.action = #selector(goBackInPreview(_:))
        backButton.toolTip = "Back to the previous place in this preview"
        backButton.setAccessibilityLabel("Back in preview")
        backButton.isHidden = true

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let header = NSStackView(views: [backButton, titleLabel])
        header.orientation = .horizontal
        header.spacing = 4
        let footer = makeFooter(place: "this place")

        for view in [header, previewView, footer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -10),
            header.heightAnchor.constraint(greaterThanOrEqualToConstant: 22),
            previewView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            previewView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.topAnchor.constraint(equalTo: previewView.bottomAnchor, constant: 8),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            root.widthAnchor.constraint(equalToConstant: Self.defaultSize.width),
            root.heightAnchor.constraint(equalToConstant: Self.defaultSize.height),
        ])
        root.setAccessibilityLabel("Link preview")
        view = root
        preferredContentSize = Self.defaultSize
        updateTitle()
    }

    /// Go and Open in Split, on the right.
    private func makeFooter(place: String) -> NSStackView {
        splitButton.target = self
        splitButton.action = #selector(openInSplit(_:))
        splitButton.toolTip = "Show \(place) in a second pane, next to where you’re reading"
        goButton.target = self
        goButton.action = #selector(go(_:))
        goButton.keyEquivalent = "\r"
        goButton.toolTip = "Go to \(place) (Return)"
        goButton.setAccessibilityLabel("Go to \(place)")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [spacer, splitButton, goButton])
        footer.orientation = .horizontal
        footer.spacing = 8
        return footer
    }

    /// The card for a citation, as tall as its fields need.
    private func loadCitationView(_ work: CitedWork) {
        let width = Self.citationWidth
        let root = PreviewRootView(frame: NSRect(x: 0, y: 0, width: width, height: 200))
        root.onPointerEntered = { [weak self] in self?.pointerHasEntered = true }
        // Holds the focus, so Return is Go and Escape closes, with no field selected.
        root.takesFocus = true
        root.onEscape = { [weak self] in self?.dismiss() }
        let card = CitationCardView(work: work, width: width - 32)
        card.onOpenURL = { [weak self] url in self?.onExternalLink?(LinkClassifier.target(of: url)) }
        citationCard = card
        let footer = makeFooter(place: "this reference")
        for view in [card, footer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            card.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            footer.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 10),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            root.widthAnchor.constraint(equalToConstant: width),
        ])
        root.setAccessibilityLabel("Citation preview")
        view = root
        root.layoutSubtreeIfNeeded()
        root.setFrameSize(root.fittingSize)
        preferredContentSize = root.fittingSize
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        // A card is as tall as its fields once laid out in place; the popover follows.
        if citation != nil {
            let fitting = view.fittingSize
            if abs(fitting.height - preferredContentSize.height) > 0.5 { preferredContentSize = fitting }
            return
        }
        // The destination is shown once the preview has its real size.
        if !didShowDestination, previewView.bounds.width > 10, previewView.bounds.height > 10 {
            didShowDestination = true
            show(destination)
        }
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        let focus: NSView = citation == nil ? previewView : view
        view.window?.initialFirstResponder = focus
        view.window?.makeFirstResponder(focus)
    }

    /// Lays the preview out now and shows the destination; tests call this
    /// after hosting the view.
    public func layoutAndShow() {
        view.layoutSubtreeIfNeeded()
        if citation == nil, !didShowDestination {
            didShowDestination = true
            show(destination)
        }
    }

    // MARK: Showing a destination

    /// Scrolls to the destination and marks it. A destination without a
    /// usable position (`/Fit`, `/FitH`, `/FitR`, `/XYZ null null`) shows the
    /// whole page: PDFKit reports them all as unspecified and doesn't fit
    /// the page itself (M0b Q7).
    func show(_ destination: PDFDestination) {
        guard let page = destination.page, let document = previewView.document else { return }
        let index = document.index(for: page)
        guard index != NSNotFound else { return }
        // The fit modes measure the current page.
        previewView.go(to: page)
        if LinkClassifier.hasPosition(destination), let target = previewView.anchor(for: destination) {
            previewView.setZoomMode(.fitWidth)
            let box = page.bounds(for: previewView.displayBox)
            // A little of what comes before, so the target isn't at the very edge.
            var anchor = target
            anchor.pointInPage = CGPoint(x: box.minX, y: min(target.pointInPage.y + 24, box.maxY))
            previewView.restore(anchor)
            previewView.targetMarker = target
        } else {
            previewView.setZoomMode(.fitPage)
            if let top = previewView.topAnchor(forPageAt: index) { previewView.restore(top) }
            previewView.targetMarker = nil
        }
    }

    /// True when the current destination is shown as a whole page.
    public var showsWholePage: Bool { !LinkClassifier.hasPosition(destination) }

    private func updateTitle() {
        guard let page = destination.page, let document = page.document else {
            titleLabel.stringValue = "Preview"
            return
        }
        let pageName = "Page \(page.label ?? String(document.index(for: page) + 1))"
        let isPageNumber = linkText.isEmpty || linkText == page.label || Int(linkText) != nil
        titleLabel.stringValue = isPageNumber ? pageName : "\(linkText) — \(pageName)"
        titleLabel.setAccessibilityLabel("Preview of \(titleLabel.stringValue)")
        backButton.isHidden = backStack.isEmpty
    }

    // MARK: Links inside the preview

    func follow(_ target: LinkTarget) {
        switch target {
        case let .destination(next):
            backStack.append(destination)
            navigate(to: next, text: "")
        case .web, .otherScheme, .blocked:
            onExternalLink?(target)
        case .named:
            NSSound.beep()
        }
    }

    private func navigate(to next: PDFDestination, text: String) {
        destination = next
        linkText = text
        updateTitle()
        show(next)
    }

    @objc public func goBackInPreview(_ sender: Any?) {
        guard let previous = backStack.popLast() else { return }
        navigate(to: previous, text: "")
    }

    // MARK: Actions

    @objc public func go(_ sender: Any?) {
        let destination = destination
        dismiss()
        onGo?(destination)
    }

    @objc public func openInSplit(_ sender: Any?) {
        let destination = destination
        dismiss()
        onOpenInSplit?(destination)
    }

    public func dismiss() {
        guard !isClosed else { return }
        onDismissRequest?()
    }

    public override func cancelOperation(_ sender: Any?) {
        dismiss()
    }

    /// Called by the presenter when the preview has gone.
    public func didClose() {
        guard !isClosed else { return }
        isClosed = true
        previewView.targetMarker = nil
        onClose?()
    }
}

/// The preview's root view: notices the pointer coming in.
private final class PreviewRootView: NSView {
    var onPointerEntered: (() -> Void)?
    /// A citation card's root takes the focus itself, and Escape from it.
    var takesFocus = false
    var onEscape: (() -> Void)?

    override var acceptsFirstResponder: Bool { takesFocus }

    override func keyDown(with event: NSEvent) {
        if takesFocus, event.keyCode == 53, let onEscape {
            onEscape()
        } else {
            super.keyDown(with: event)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if trackingAreas.isEmpty {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }
    }

    override func mouseEntered(with event: NSEvent) {
        onPointerEntered?()
    }
}

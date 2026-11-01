import AppKit
import PDFKit
import ReaderCore

/// A request to preview an internal link (A3).
public struct LinkPreviewRequest {
    public enum Trigger: Sendable, Equatable {
        case hover, forceClick, keyboard
    }

    public let destination: PDFDestination
    /// The words the link covers ("Figure 3"), or empty.
    public let linkText: String
    /// The link's rectangle in the requesting view's coordinates, for
    /// pointing the popover at it.
    public let sourceRect: NSRect
    public let trigger: Trigger

    public init(destination: PDFDestination, linkText: String, sourceRect: NSRect, trigger: Trigger) {
        self.destination = destination
        self.linkText = linkText
        self.sourceRect = sourceRect
        self.trigger = trigger
    }
}

/// A link collected for keyboard link focus.
public struct FocusableLink {
    public let annotation: PDFAnnotation
    public let page: PDFPage
    public let target: LinkTarget
    /// What VoiceOver says: "Link to Figure 3, page 12".
    public let label: String
}

struct PendingLink {
    let annotation: PDFAnnotation
    /// A Force Click previewed it, so releasing doesn't follow it.
    var previewed = false
}

extension ReaderPDFView {
    public static let openRepresentedLinkSelector = NSSelectorFromString("openRepresentedLink:")

    // MARK: Finding links

    /// The link under a point in this view's coordinates. Only link
    /// annotations count, even when another annotation sits on top.
    public func link(at point: CGPoint) -> (annotation: PDFAnnotation, target: LinkTarget)? {
        guard document != nil, let page = page(for: point, nearest: false) else { return nil }
        let pagePoint = convert(point, to: page)
        for annotation in page.annotations.reversed() where annotation.type == "Link" && annotation.bounds.contains(pagePoint) {
            if let target = LinkClassifier.target(of: annotation) { return (annotation, target) }
        }
        return nil
    }

    /// The words under a link, collapsed to one line.
    public static func text(of annotation: PDFAnnotation) -> String {
        guard let page = annotation.page, let raw = page.selection(for: annotation.bounds)?.string else { return "" }
        let words = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return words.count > 60 ? String(words.prefix(59)) + "…" : words
    }

    /// The accessible name of a link (Rule 8).
    public static func accessibilityLabel(for target: LinkTarget, text: String) -> String {
        switch target {
        case let .destination(destination):
            guard let page = destination.page, let document = page.document else { return "Link" }
            let index = document.index(for: page)
            let pageName = "page \(page.label ?? String(index + 1))"
            // A bare number is usually the page or a citation; the page says more.
            if text.isEmpty || text == page.label || text == String(index + 1) { return "Link to \(pageName)" }
            return "Link to \(text), \(pageName)"
        case let .web(url), let .otherScheme(url):
            return "Link to \(url.absoluteString)"
        case let .named(name):
            return "Link: \(LinkTarget.description(of: name))"
        case let .blocked(type):
            return text.isEmpty ? "Blocked link (\(type))" : "Blocked link, \(text) (\(type))"
        }
    }

    // MARK: Activating

    /// Hands a link to the owner. With no owner, nothing happens.
    public func activate(_ target: LinkTarget) {
        onActivateLink?(target)
    }

    /// Every PDFKit activation path that survives the click interception
    /// (accessibility, keyboard, paths not anticipated) ends here. Super is
    /// never called, so PDFKit never acts on a link by itself (M0b Q2).
    public override func perform(_ action: PDFAction) {
        activate(LinkClassifier.target(of: action))
    }

    /// PDFKit's private context-menu action, which would open the URL with
    /// NSWorkspace directly and skip the delegate. Same selector, so this
    /// replaces it.
    @objc(openRepresentedLink:)
    public func openRepresentedLink(_ sender: Any?) {
        guard let url = (sender as? NSMenuItem)?.representedObject as? URL else { return }
        activate(Self.target(for: url))
    }

    static func target(for url: URL) -> LinkTarget {
        LinkClassifier.target(of: url)
    }

    /// Look Up (Force Click, three-finger tap) over any link is ours: an
    /// internal link previews, and nothing else reaches PDFKit, whose own
    /// handling could show a web page preview (A4). Returns true when the
    /// event was handled here.
    @discardableResult
    public func handleLookUpOverLink(at point: CGPoint) -> Bool {
        guard let link = link(at: point) else { return false }
        if link.target.isInternal {
            requestPreview(of: link.annotation, target: link.target, trigger: .forceClick)
        }
        return true
    }

    // MARK: Clicks

    /// PDFKit acts on links during mouse-down (M0b Q2), so a click on a link
    /// is swallowed here and followed on the matching mouse-up.
    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let link = link(at: point) else {
            pendingLink = nil
            if handleAnnotationMouseDown(event, at: point) { return }
            super.mouseDown(with: event)
            return
        }
        // Not calling super skips PDFKit's own first-responder change.
        window?.makeFirstResponder(self)
        cancelHover()
        endLinkFocus()
        pendingLink = PendingLink(annotation: link.annotation)
    }

    public override func mouseDragged(with event: NSEvent) {
        if pendingLink != nil { return }
        handleAnnotationMouseDragged(at: convert(event.locationInWindow, from: nil))
        if let pending = pendingAnnotationClick, !["Highlight", "Underline", "StrikeOut", "Squiggly"].contains(pending.annotation.type ?? "") {
            return
        }
        super.mouseDragged(with: event)
    }

    public override func mouseUp(with event: NSEvent) {
        lastPressureStage = 0
        guard let pending = pendingLink else {
            let swallowed = pendingAnnotationClick.map { !["Highlight", "Underline", "StrikeOut", "Squiggly"].contains($0.annotation.type ?? "") } ?? false
            if !swallowed { super.mouseUp(with: event) }
            handleAnnotationMouseUp()
            return
        }
        pendingLink = nil
        // The second click of a double-click is swallowed but not followed
        // again, as in a browser; the first click already followed it.
        guard event.clickCount <= 1 else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard !pending.previewed, let link = link(at: point), link.annotation === pending.annotation else { return }
        activate(link.target)
    }

    // MARK: Force Click

    public override func pressureChange(with event: NSEvent) {
        handlePressureStage(event.stage, at: convert(event.locationInWindow, from: nil))
    }

    /// A firm press (stage 2) on an internal link previews it, and the
    /// release then doesn't follow it. Pressure events can't be synthesised
    /// (M0b Q8), so tests call this directly.
    public func handlePressureStage(_ stage: Int, at point: CGPoint) {
        defer { lastPressureStage = stage }
        guard stage >= 2, lastPressureStage < 2 else { return }
        if previewLink(at: point, trigger: .forceClick) {
            pendingLink?.previewed = true
        }
    }

    /// Previews the internal link at `point`, if there is one.
    @discardableResult
    public func previewLink(at point: CGPoint, trigger: LinkPreviewRequest.Trigger) -> Bool {
        guard let link = link(at: point), link.target.isInternal else { return false }
        return requestPreview(of: link.annotation, target: link.target, trigger: trigger)
    }

    @discardableResult
    func requestPreview(of annotation: PDFAnnotation, target: LinkTarget, trigger: LinkPreviewRequest.Trigger) -> Bool {
        guard let destination = target.destination, let page = annotation.page else { return false }
        cancelHover()
        let rect = convert(annotation.bounds, from: page)
        onPreviewLink?(LinkPreviewRequest(destination: destination, linkText: Self.text(of: annotation), sourceRect: rect, trigger: trigger))
        return true
    }

    func removeImmediateActionRecognizers() {
        for recognizer in gestureRecognizers where Self.isImmediateAction(recognizer) {
            removeGestureRecognizer(recognizer)
        }
    }

    /// AppKit's recognizer for Force Click actions; its class isn't public.
    public static func isImmediateAction(_ recognizer: NSGestureRecognizer) -> Bool {
        String(describing: type(of: recognizer)) == "NSImmediateActionGestureRecognizer"
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeImmediateActionRecognizers()
    }

    public override func addGestureRecognizer(_ gestureRecognizer: NSGestureRecognizer) {
        // PDFKit may install it again later; it never comes back.
        if Self.isImmediateAction(gestureRecognizer) { return }
        super.addGestureRecognizer(gestureRecognizer)
    }

    // MARK: Hover

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if hoverTrackingArea == nil {
            let area = NSTrackingArea(
                rect: .zero,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self, userInfo: ["lectern": "hover"]
            )
            addTrackingArea(area)
            hoverTrackingArea = area
        }
    }

    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        handleHover(at: convert(event.locationInWindow, from: nil))
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if (event.trackingArea?.userInfo?["lectern"] as? String) == "hover" { handleHover(at: nil) }
    }

    /// The pointer is at `point` (nil: it left the view). Resting on an
    /// internal link for `hoverDelay` previews it; any link's target is
    /// reported so its URL can be shown. Tracking-area delivery needs a real
    /// cursor (M0b Q8), so tests call this directly.
    public func handleHover(at point: CGPoint?) {
        let link = point.flatMap { self.link(at: $0) }
        guard link?.annotation !== hoveredLink else { return }
        cancelHover()
        hoveredLink = link?.annotation
        if !isLinkFocusActive { onHighlightedLinkChange?(link?.target) }
        guard let link, link.target.isInternal, previewsOnHover, pendingLink == nil else { return }
        // A run-loop timer in the common modes, so it also fires while a
        // menu or a drag is tracking. Any change of link invalidates it, so
        // the hovered link when it fires is the one it was started for.
        let timer = Timer(timeInterval: Self.hoverDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let annotation = self.hoveredLink, let target = LinkClassifier.target(of: annotation) else { return }
                self.hoverTimer = nil
                self.requestPreview(of: annotation, target: target, trigger: .hover)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    /// True while a hover preview is waiting for its delay.
    public var isHoverPreviewPending: Bool { hoverTimer != nil }

    func cancelHover() {
        hoverTimer?.invalidate()
        hoverTimer = nil
    }

    // MARK: Keyboard link focus (Rule 8)

    public var isLinkFocusActive: Bool { focusedLinkIndex != nil }

    public var focusedLink: FocusableLink? {
        focusedLinkIndex.flatMap { focusableLinks.indices.contains($0) ? focusableLinks[$0] : nil }
    }

    /// Collects the links on the visible part of the pages, in reading
    /// order, and focuses the first. Returns false if there are none.
    @discardableResult
    public func beginLinkFocus() -> Bool {
        let links = visibleLinks()
        guard !links.isEmpty else {
            endLinkFocus()
            NSSound.beep()
            return false
        }
        cancelHover()
        focusableLinks = links
        linkElements = links.enumerated().map { index, link in
            let element = LinkAccessibilityElement(owner: self, index: index)
            element.setAccessibilityLabel(link.label)
            return element
        }
        focusLink(at: 0)
        return true
    }

    public func endLinkFocus() {
        guard focusedLinkIndex != nil || !focusableLinks.isEmpty else { return }
        focusedLinkIndex = nil
        focusableLinks = []
        linkElements = []
        updateLinkOverlays()
        onHighlightedLinkChange?(nil)
    }

    public func toggleLinkFocus() {
        if isLinkFocusActive { endLinkFocus() } else { beginLinkFocus() }
    }

    /// Moves the focus ring, wrapping at either end.
    public func moveLinkFocus(by step: Int) {
        guard let index = focusedLinkIndex, !focusableLinks.isEmpty else { return }
        focusLink(at: (index + step % focusableLinks.count + focusableLinks.count) % focusableLinks.count)
    }

    func focusLink(at index: Int) {
        guard focusableLinks.indices.contains(index) else { return }
        focusedLinkIndex = index
        updateLinkOverlays()
        let link = focusableLinks[index]
        onHighlightedLinkChange?(link.target)
        if linkElements.indices.contains(index) {
            let element = linkElements[index]
            element.setAccessibilityFocused(true)
            NSAccessibility.post(element: element, notification: .focusedUIElementChanged)
        }
    }

    /// Space: previews the focused link, if it is internal.
    public func previewFocusedLink() {
        guard let link = focusedLink else { return }
        if !requestPreview(of: link.annotation, target: link.target, trigger: .keyboard) { NSSound.beep() }
    }

    /// Return: follows the focused link and leaves link focus.
    public func followFocusedLink() {
        guard let link = focusedLink else { return }
        endLinkFocus()
        activate(link.target)
    }

    func followLink(atFocusIndex index: Int) -> Bool {
        guard focusableLinks.indices.contains(index) else { return false }
        focusLink(at: index)
        followFocusedLink()
        return true
    }

    /// ⌥Tab starts link focus; while it is on, Tab and the arrows move,
    /// Space previews, Return follows and Escape leaves. Any other key leaves
    /// link focus and does what it normally does.
    func handleLinkFocusKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if !isLinkFocusActive {
            guard event.keyCode == 48, modifiers == .option else { return false }
            beginLinkFocus()
            return true
        }
        switch event.keyCode {
        case 48 where modifiers == .option:
            endLinkFocus()
        case 48:
            moveLinkFocus(by: modifiers.contains(.shift) ? -1 : 1)
        case let arrow where (123...126).contains(arrow) && modifiers.isEmpty:
            moveLinkFocus(by: arrow == 124 || arrow == 125 ? 1 : -1)
        case 49 where modifiers.isEmpty:
            previewFocusedLink()
        case 36, 76:
            followFocusedLink()
        case 53:
            endLinkFocus()
        default:
            endLinkFocus()
            return false
        }
        return true
    }

    /// The part of the view not under the toolbar, in view coordinates.
    var unobscuredRect: NSRect {
        let insets = safeAreaInsets
        return NSRect(
            x: bounds.minX + insets.left, y: isFlipped ? bounds.minY + insets.top : bounds.minY + insets.bottom,
            width: bounds.width - insets.left - insets.right, height: bounds.height - insets.top - insets.bottom
        )
    }

    /// The links whose rectangles are at least partly visible, in reading
    /// order: by page, then by where the link's text falls in the page's
    /// text (which follows columns), then top to bottom and left to right.
    func visibleLinks() -> [FocusableLink] {
        guard let document else { return [] }
        let visible = unobscuredRect
        var found: [(key: (Int, Int, CGFloat, CGFloat), link: FocusableLink)] = []
        // The pages under the visible area's corners and everything between.
        // Measured, as `visiblePages` lags behind a scroll made in code.
        let corners = [CGPoint(x: visible.minX, y: visible.minY), CGPoint(x: visible.maxX, y: visible.minY),
                       CGPoint(x: visible.minX, y: visible.maxY), CGPoint(x: visible.maxX, y: visible.maxY)]
        let indices = corners.compactMap { page(for: $0, nearest: true) }.map { document.index(for: $0) }.filter { $0 != NSNotFound }
        guard let first = indices.min(), let last = indices.max() else { return [] }
        for pageIndex in first...last {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations where annotation.type == "Link" {
                guard let target = LinkClassifier.target(of: annotation) else { continue }
                let rect = convert(annotation.bounds, from: page)
                guard rect.intersects(visible) else { continue }
                let text = Self.text(of: annotation)
                let label = Self.accessibilityLabel(for: target, text: text)
                let bounds = annotation.bounds
                let probes = [CGPoint(x: bounds.midX, y: bounds.midY), CGPoint(x: bounds.minX + 2, y: bounds.midY)]
                let characterIndex = probes.lazy.map { page.characterIndex(at: $0) }.first { $0 >= 0 && $0 != NSNotFound } ?? Int.max
                found.append(((pageIndex, characterIndex, -bounds.maxY, bounds.minX), FocusableLink(annotation: annotation, page: page, target: target, label: label)))
            }
        }
        return found.sorted { $0.key < $1.key }.map(\.link)
    }

    // MARK: Overlays

    /// Places the focus ring and the preview's target marker over their
    /// page positions; called after every scroll and layout.
    func updateLinkOverlays() {
        if let link = focusedLink {
            let rect = convert(link.annotation.bounds, from: link.page).insetBy(dx: -3, dy: -3)
            focusRing.frame = rect
            focusRing.isHidden = false
            if let index = focusedLinkIndex, linkElements.indices.contains(index) {
                for (offset, element) in linkElements.enumerated() {
                    let link = focusableLinks[offset]
                    element.setAccessibilityFrameInParentSpace(convert(link.annotation.bounds, from: link.page))
                }
            }
        } else {
            focusRing.isHidden = true
        }
        if let marker = targetMarker, let page = document?.page(at: marker.pageIndex) {
            let box = page.bounds(for: displayBox)
            // About two lines below the destination's top, across the page.
            let top = min(marker.pointInPage.y, box.maxY)
            let band = CGRect(x: box.minX, y: max(box.minY, top - 30), width: box.width, height: min(30, top - box.minY))
            targetMarkerView.frame = convert(band, from: page)
            targetMarkerView.isHidden = false
        } else {
            targetMarkerView.isHidden = true
        }
    }

    // MARK: Accessibility

    public override func accessibilityChildren() -> [Any]? {
        // PDFKit's own children (the text) stay; the links are added.
        let own = super.accessibilityChildren() ?? []
        return linkElements.isEmpty ? own : own + linkElements
    }
}

/// One link exposed to VoiceOver while link focus is on (Rule 8).
nonisolated final class LinkAccessibilityElement: NSAccessibilityElement {
    private weak var owner: ReaderPDFView?
    private let index: Int

    @MainActor init(owner: ReaderPDFView, index: Int) {
        self.owner = owner
        self.index = index
        super.init()
        setAccessibilityRole(.link)
        setAccessibilityParent(owner)
    }

    override func accessibilityPerformPress() -> Bool {
        // Accessibility calls arrive on the main thread.
        let owner = owner
        let index = index
        return MainActor.assumeIsolated { owner?.followLink(atFocusIndex: index) ?? false }
    }
}

/// Routes PDFKit's delegate callbacks through the link policy instead of its
/// defaults, which open URLs with NSWorkspace (M0b Q2).
final class LinkSafetyDelegate: NSObject, PDFViewDelegate {
    func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
        (sender as? ReaderPDFView)?.activate(ReaderPDFView.target(for: url))
    }

    func pdfViewOpenPDF(_ sender: PDFView, forRemoteGoToAction action: PDFActionRemoteGoTo) {
        // Never read `action.url`: it traps when the document has no file URL.
        (sender as? ReaderPDFView)?.activate(.blocked(actionType: "GoToR"))
    }
}

/// The keyboard focus ring around the focused link. Drawn over the view,
/// never into the document.
final class LinkFocusRingView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 4, yRadius: 4)
        path.lineWidth = 3
        NSColor.keyboardFocusIndicatorColor.setStroke()
        path.stroke()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
}

/// Marks a preview's target: a soft band with a bar at its leading edge, so
/// the mark doesn't depend on colour alone.
final class TargetMarkerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        bounds.fill()
        NSColor.controlAccentColor.setFill()
        NSRect(x: bounds.minX, y: bounds.minY, width: 4, height: bounds.height).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
}

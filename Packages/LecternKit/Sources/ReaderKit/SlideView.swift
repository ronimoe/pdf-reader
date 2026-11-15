import AppKit
import PDFKit
import ReaderCore

/// One slide of a presentation: the page fitted to the view and centred on black.
///
/// It draws the reader's own `PDFDocument`, so the view rotation (B9) and unsaved annotations
/// show as they do in the reader. It isn't a `PDFView`: there is nothing to scroll, select or
/// preview, and none of PDFView's own link handling to intercept. Links are found here and
/// classified with `LinkClassifier` (A4), so they go through the same policy as in the reader.
public final class SlideView: NSView {
    public var document: PDFDocument? {
        didSet { slideDidChange() }
    }

    /// The page shown, an index into `document`.
    public var pageIndex = 0 {
        didSet { if pageIndex != oldValue { slideDidChange() } }
    }

    /// A blanked screen shows black or white instead of the slide.
    public var blank: SlideNavigator.Blank? {
        didSet { if blank != oldValue { slideDidChange() } }
    }

    /// A click on a link, released on the same link.
    public var onActivateLink: ((LinkTarget) -> Void)?
    /// A click anywhere else: the next slide.
    public var onClick: (() -> Void)?
    /// The pointer moved, to show it until it rests again.
    public var onPointerMoved: (() -> Void)?

    private var pressedLink: PDFAnnotation?
    private var isPressed = false
    private var pointerTrackingArea: NSTrackingArea?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isOpaque: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    /// The page shown, or nil for an index outside the document.
    public var page: PDFPage? {
        guard let document, pageIndex >= 0, pageIndex < document.pageCount else { return nil }
        return document.page(at: pageIndex)
    }

    /// Where the page goes in the view now. The page's `rotation` already includes the view
    /// rotation, which `ReaderDocument` applies to the shared pages.
    public var layout: SlideLayout? {
        guard let page else { return nil }
        return SlideLayout(pageBox: page.bounds(for: .cropBox), rotation: page.rotation, fitting: bounds)
    }

    /// Draws again: after the page's rotation or annotations changed in the reader.
    public func refresh() {
        slideDidChange()
    }

    private func slideDidChange() {
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        // Fixed colours, never the appearance's: the slide is on a projector, not in the UI.
        (blank == .white ? NSColor.white : NSColor.black).setFill()
        dirtyRect.fill()
        guard blank == nil, let page, let layout, layout.scale > 0,
              let context = NSGraphicsContext.current?.cgContext
        else { return }
        // On white, as PDFKit draws pages: many have no background of their own.
        NSColor.white.setFill()
        layout.frame.fill()
        context.saveGState()
        context.translateBy(x: layout.frame.minX, y: layout.frame.minY)
        context.scaleBy(x: layout.scale, y: layout.scale)
        context.interpolationQuality = .high
        page.draw(with: .cropBox, to: context)
        context.restoreGState()
    }

    // MARK: Links

    /// The link under a point in this view's coordinates. Only link annotations count, even
    /// when another annotation sits on top, as in the reader.
    public func link(at point: CGPoint) -> (annotation: PDFAnnotation, target: LinkTarget)? {
        guard blank == nil, let page, let layout, layout.frame.contains(point) else { return nil }
        let pagePoint = layout.pagePoint(forViewPoint: point)
        for annotation in page.annotations.reversed() where annotation.type == "Link" && annotation.bounds.contains(pagePoint) {
            if let target = LinkClassifier.target(of: annotation) { return (annotation, target) }
        }
        return nil
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isPressed = true
        pressedLink = link(at: convert(event.locationInWindow, from: nil))?.annotation
    }

    public override func mouseUp(with event: NSEvent) {
        guard isPressed else { return }
        isPressed = false
        let pressed = pressedLink
        pressedLink = nil
        handleClick(pressedOn: pressed, releasedAt: convert(event.locationInWindow, from: nil))
    }

    /// A click on a link follows it when it is released on the same link, as in the reader. One
    /// that started on a link and ended off it does nothing; any other click is the next slide.
    /// Tests call this directly, as synthesised mouse events need a visible window.
    public func handleClick(pressedOn pressed: PDFAnnotation?, releasedAt point: CGPoint) {
        if let pressed {
            if let link = link(at: point), link.annotation === pressed { onActivateLink?(link.target) }
            return
        }
        onClick?()
    }

    public override func resetCursorRects() {
        guard blank == nil, let page, let layout else { return }
        for annotation in page.annotations where annotation.type == "Link" {
            let rect = layout.viewRect(forPageRect: annotation.bounds).intersection(bounds)
            if !rect.isEmpty { addCursorRect(rect, cursor: .pointingHand) }
        }
    }

    // MARK: Pointer

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if pointerTrackingArea == nil {
            let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(area)
            pointerTrackingArea = area
        }
    }

    public override func mouseMoved(with event: NSEvent) {
        onPointerMoved?()
    }
}

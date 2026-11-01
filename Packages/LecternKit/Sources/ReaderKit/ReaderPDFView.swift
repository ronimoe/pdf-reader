import AppKit
import PDFKit
import ReaderCore
import UniformTypeIdentifiers

/// The reading surface. Later milestones add link interception and keyboard
/// link focus here; this is the only type that subclasses PDFView.
///
/// The view owns the zoom mode so that the fit modes can be recomputed when
/// its size changes. Everything else in `ViewSettings` is applied by `apply`.
///
/// It also keeps the reader's place (A3, architecture §4.5): zoom, resize,
/// layout and rotation changes capture a `ReadingAnchor` first and restore it
/// afterwards, so the same point of the same page stays at the top-left of
/// the visible area.
public final class ReaderPDFView: PDFView {
    /// Called after the user changes the zoom directly (pinch, smart
    /// magnify), with the new fixed scale.
    public var onUserZoom: ((CGFloat) -> Void)?
    /// Called when Copy is chosen but the document doesn't allow copying.
    public var onCopyBlocked: (() -> Void)?
    /// Called with PDF files dropped onto the view, to open them as documents.
    public var onOpenFiles: (([URL]) -> Void)?

    public private(set) var zoomMode: ZoomMode = .fitWidth
    /// Our own scale changes post `PDFViewScaleChanged` too; this tells them
    /// apart from the user's.
    private var isApplyingZoom = false
    /// The page the fit modes measure. Fixed when a fit mode is chosen, so
    /// scrolling through pages of mixed sizes doesn't keep rescaling.
    private var fitReferencePageIndex = 0
    /// The visible size the current fit was computed for.
    private var fittedSize: CGSize = .zero

    // MARK: Links (A3, A4, architecture §4.4)

    /// Called for every link the user activates: a click, Return in link
    /// focus, a PDFKit path that ends in `perform(_:)`, the delegate, or the
    /// private "Open Link" action. Nothing else ever acts on a link; without
    /// a handler a link does nothing.
    public var onActivateLink: ((LinkTarget) -> Void)?
    /// Called to preview an internal link (hover, Force Click, Space in link
    /// focus). The view's own place never changes.
    public var onPreviewLink: ((LinkPreviewRequest) -> Void)?
    /// Called when the link under the pointer, or the focused link, changes,
    /// so its full URL can be shown (A4). Nil when there is none.
    public var onHighlightedLinkChange: ((LinkTarget?) -> Void)?
    /// Hover previews (A3). The window sets this from the user's preference.
    public var previewsOnHover = true
    /// How long the pointer rests on a link before it previews.
    public static var hoverDelay: TimeInterval = 0.5

    /// The link a swallowed mouse-down landed on; followed on mouse-up.
    var pendingLink: PendingLink?
    var lastPressureStage = 0
    var hoveredLink: PDFAnnotation?
    var hoverTimer: Timer?
    var hoverTrackingArea: NSTrackingArea?
    /// Links collected for keyboard link focus, in reading order.
    public internal(set) var focusableLinks: [FocusableLink] = []
    public internal(set) var focusedLinkIndex: Int?
    var linkElements: [LinkAccessibilityElement] = []
    let focusRing = LinkFocusRingView()
    let targetMarkerView = TargetMarkerView()
    /// The place a preview marks (A3): drawn over this view only, never
    /// as an annotation on the shared document.
    public var targetMarker: ReadingAnchor? {
        didSet { updateLinkOverlays() }
    }
    /// Retained here: PDFView's delegate is weak. Its URL and remote-GoTo
    /// callbacks route through the same policy instead of PDFKit's defaults.
    private let linkDelegate = LinkSafetyDelegate()

    /// Called whenever the visible part of the document moves, for saving
    /// the reading position. Never a history entry.
    public var onVisibleAreaChange: (() -> Void)?
    /// Called for Escape in the reading area. Returns true if it was used
    /// (ending a search, say).
    public var onCancel: (() -> Bool)?

    /// The place to keep: the anchor last restored, or where the user last
    /// scrolled to. Keeping it, rather than measuring again before every
    /// change, stops rounding errors accumulating into drift over a live
    /// resize, survives the moment mid-resize when the safe area reads as
    /// zero, and lets content moved by a later layout pass be put back.
    private var keptAnchor: ReadingAnchor?
    private var lastSafeAreaInsets = NSEdgeInsetsZero
    /// True while the view itself is moving the content (restoring an anchor
    /// or applying geometry), so those scrolls don't count as the user's.
    private var isAdjustingGeometry = false
    private var observedClipView: NSClipView?
    /// When the user last scrolled, clicked, typed or gestured in this view.
    private var lastUserInput: TimeInterval = -.infinity
    private var inputMonitor: Any?

    // MARK: Annotations (B4) and forms (A5)

    /// The annotation the user selected in this view: outlined over the page, and what Delete,
    /// Change Colour and Edit act on.
    public internal(set) var selectedAnnotation: PDFAnnotation?
    /// Called when the selected annotation changes (a click, Escape, a re-bind).
    public var onAnnotationSelectionChange: ((PDFAnnotation?) -> Void)?
    /// Called after a click on an annotation selected it, with the click count (2 edits it).
    public var onAnnotationClick: ((PDFAnnotation, Int) -> Void)?
    /// Called when ⌫ or ⌦ is pressed with an annotation selected. Returns true if it was used.
    public var onDeleteKey: (() -> Bool)?
    /// The selection control's actions and colour, handled by the window.
    public var onMarkupAction: ((MarkupAction) -> Void)? {
        didSet { selectionBar.onAction = onMarkupAction }
    }
    public var onMarkupColor: ((AnnotationColorPreset) -> Void)? {
        didSet { selectionBar.onColor = onMarkupColor }
    }
    /// The colour new markup gets; shown on the selection control.
    public var markupColor: AnnotationColorPreset = .default {
        didSet { selectionBar.markupColor = markupColor }
    }
    /// Whether the selection control appears for selected text.
    public var showsSelectionBar = true
    /// Items for the context menu over an annotation (it is selected first) or, with nil, over
    /// the page; supplied by the window.
    public var annotationContextMenuItems: (PDFAnnotation?) -> [NSMenuItem] = { _ in [] }
    /// Where the last context menu was opened, for Add Note Here.
    public internal(set) var contextClickLocation: (page: PDFPage, point: CGPoint)?
    var pendingAnnotationClick: PendingAnnotationClick?
    /// The current press began on a form widget, so none of it reaches PDFKit (A5).
    var swallowsWidgetPress = false
    var formFieldsKnown: Bool?
    let annotationOutline = AnnotationOutlineView()
    public let selectionBar = SelectionActionBar()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        Self.disableAutomaticAnalysis(of: self)
        autoScales = false
        displayMode = .singlePageContinuous
        displaysPageBreaks = true
        minScaleFactor = ZoomMode.minimumScale
        maxScaleFactor = ZoomMode.maximumScale
        // Behind the pages only; the pages themselves are never recoloured (Rule 4).
        backgroundColor = .underPageBackgroundColor
        registerForDraggedTypes([.fileURL])
        NotificationCenter.default.addObserver(
            self, selector: #selector(scaleDidChange(_:)), name: .PDFViewScaleChanged, object: self
        )
        observeClipView()
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.userInputEvents) { [weak self] event in
            MainActor.assumeIsolated { self?.noteInputIfMine(event) }
            return event
        }
        delegate = linkDelegate
        // Force Click goes to pressureChange only, never to PDFKit's own
        // immediate action (Look Up, link previews that could fetch a page).
        pressureConfiguration = NSPressureConfiguration(pressureBehavior: .primaryDeepClick)
        removeImmediateActionRecognizers()
        addSubview(targetMarkerView)
        addSubview(focusRing)
        addSubview(annotationOutline)
        addSubview(selectionBar)
        NotificationCenter.default.addObserver(
            self, selector: #selector(selectionDidChange(_:)), name: .PDFViewSelectionChanged, object: self
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
    }

    /// Keeps this view alive until the main queue has run the work already on it.
    /// Call it when the view is about to be freed (a pane, preview or window closing).
    ///
    /// A page rotation makes PDFKit queue a relayout of each view on the main
    /// queue. If the view is freed before those blocks run, the relayout
    /// dereferences null in `-[PDFDocumentView layoutDocumentView]` (seen in the
    /// tests). The blocks are queued while the rotation is applied, so one block
    /// queued here runs after them. In the app, a close typed during a slow
    /// rotation can probably be handled before the main queue drains, because
    /// AppKit hands out events that are already waiting first. Only the window
    /// close is reproduced (`SplitView` tests); the pane and preview closes call
    /// this as a precaution, since AppKit kept those views alive in the tests.
    public func outliveQueuedPDFKitWork() {
        DispatchQueue.main.async { withExtendedLifetime(self) {} }
    }

    /// Shows `document` and resets per-document view state. Always use this
    /// rather than assigning `document`.
    ///
    /// `document` is deliberately not overridden: PDFKit reads it from its own
    /// background queues, and a main-actor override traps there (seen in the
    /// field from PDFKit's form-detection queue).
    public func show(_ document: PDFDocument?) {
        self.document = document
        formFieldsKnown = nil
        pendingAnnotationClick = nil
        swallowsWidgetPress = false
        hideSelectionBar()
        if selectedAnnotation != nil { selectAnnotation(nil) }
        keptAnchor = nil
        fitReferencePageIndex = 0
        endLinkFocus()
        cancelHover()
        pendingLink = nil
        targetMarker = nil
        applyZoom()
        observeClipView()
    }

    /// Keys of PDFKit's private, undocumented automatic page analysis: Vision
    /// based form-field detection, OCR and table detection. They run on a
    /// background queue as pages scroll into view and add annotations to the
    /// document on their own. Lectern ships no AI or analysis features and never
    /// changes a document behind the reader's back, so both are switched off.
    /// Each key is only touched if this PDFKit version has it.
    static let automaticAnalysisKeys = ["formDetectionEnabled", "documentAnalysisEnabled"]

    static func disableAutomaticAnalysis(of view: PDFView) {
        for key in automaticAnalysisKeys {
            let setter = NSSelectorFromString("set" + key.prefix(1).uppercased() + key.dropFirst() + ":")
            if view.responds(to: setter) {
                view.setValue(false, forKey: key)
            }
        }
    }

    // MARK: Layout (B1)

    public static func displayMode(pages: ViewSettings.Pages, scrolling: ViewSettings.Scrolling) -> PDFDisplayMode {
        switch (pages, scrolling) {
        case (.single, .continuous): .singlePageContinuous
        case (.single, .paged): .singlePage
        case (.twoUp, .continuous): .twoUpContinuous
        case (.twoUp, .paged): .twoUp
        }
    }

    /// Applies the layout and zoom in `settings`, keeping the reader's place.
    /// Rotation lives in the document model and is applied by its owner
    /// inside `preservingAnchor`, which then calls this to re-fit.
    public func apply(_ settings: ViewSettings, hints: DocumentLayoutHints) {
        preservingAnchor {
            withZoomApplied {
                displayMode = Self.displayMode(pages: settings.pages, scrolling: settings.scrolling)
                displaysAsBook = settings.effectiveCoverPageAlone(hints: hints)
                displaysRTL = settings.effectiveRightToLeft(hints: hints)
                layoutDocumentView()
            }
            setZoomMode(settings.zoom)
        }
    }

    // MARK: Zoom

    public func setZoomMode(_ mode: ZoomMode) {
        zoomMode = mode
        if mode.isFit, let document, let page = currentPage {
            fitReferencePageIndex = document.index(for: page)
        }
        preservingAnchor { applyZoom() }
    }

    /// The part of the view not covered by the toolbar (the window uses a
    /// full-size content view), less a legacy scroller if one is showing.
    public var visibleSize: CGSize {
        let insets = safeAreaInsets
        var width = bounds.width - insets.left - insets.right
        let height = bounds.height - insets.top - insets.bottom
        if NSScroller.preferredScrollerStyle == .legacy {
            width -= NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        }
        // A point of slack keeps a horizontal scroller from appearing.
        return CGSize(width: max(1, width - 1), height: max(1, height - 1))
    }

    private func applyZoom() {
        guard document != nil else { return }
        switch zoomMode {
        case .scale(let scale):
            withZoomApplied { scaleFactor = min(max(scale, minScaleFactor), maxScaleFactor) }
        case .fitPage, .fitWidth:
            refit(force: true)
        }
    }

    /// Scales the reference page's row (one page, or a spread in two-up) to
    /// the visible width, or to the whole visible area for Fit Page.
    private func refit(force: Bool) {
        guard zoomMode.isFit, let document, document.pageCount > 0 else { return }
        let size = visibleSize
        guard force || size != fittedSize else { return }
        fittedSize = size
        let index = min(fitReferencePageIndex, document.pageCount - 1)
        guard let page = document.page(at: index) else { return }
        preservingAnchor {
            // rowSize(for:) is measured at the current scale and its margins don't
            // scale with it, so refine once from the first estimate.
            for _ in 0..<2 {
                let row = rowSize(for: page)
                guard row.width > 0, row.height > 0, scaleFactor > 0 else { return }
                let widthScale = scaleFactor * size.width / row.width
                let heightScale = scaleFactor * size.height / row.height
                let target = zoomMode == .fitPage ? min(widthScale, heightScale) : widthScale
                withZoomApplied { scaleFactor = min(max(target, minScaleFactor), maxScaleFactor) }
            }
        }
    }

    private func withZoomApplied(_ body: () -> Void) {
        let wasApplying = isApplyingZoom
        isApplyingZoom = true
        body()
        isApplyingZoom = wasApplying
    }

    @objc private func scaleDidChange(_ notification: Notification) {
        guard !isApplyingZoom, document != nil else { return }
        // A pinch zooms around the pointer; where it leaves the reader is
        // the new place.
        keptAnchor = visibleAnchor
        zoomMode = .scale(scaleFactor)
        onUserZoom?(scaleFactor)
    }

    public override func setFrameSize(_ newSize: NSSize) {
        guard newSize != frame.size, document != nil else {
            super.setFrameSize(newSize)
            refit(force: false)
            return
        }
        preservingAnchor {
            super.setFrameSize(newSize)
            refit(force: false)
        }
    }

    public override func layout() {
        super.layout()
        // PDFKit may build or replace its scroll view after the document
        // changed notification; follow whichever clip view is current.
        observeClipView()
        updateContentInsets()
        // Safe-area changes (toolbar shown or hidden, full screen) arrive as
        // layout passes without a frame change.
        refit(force: false)
        let insets = safeAreaInsets
        if !NSEdgeInsetsEqual(insets, lastSafeAreaInsets) {
            lastSafeAreaInsets = insets
            if let keptAnchor { restore(keptAnchor) }
        }
        updateLinkOverlays()
        updateAnnotationOverlays()
    }

    /// The window's content runs under the toolbar (full-size content view).
    /// The scroll area still does, but the content starts below it: the
    /// scroll view's insets follow the safe area, so the top of page 1 is
    /// visible at the top of a document.
    func updateContentInsets() {
        guard let scrollView else { return }
        let insets = safeAreaInsets
        let wanted = NSEdgeInsets(top: insets.top, left: 0, bottom: insets.bottom, right: 0)
        if scrollView.automaticallyAdjustsContentInsets { scrollView.automaticallyAdjustsContentInsets = false }
        if !NSEdgeInsetsEqual(scrollView.contentInsets, wanted) { scrollView.contentInsets = wanted }
    }

    // MARK: Keeping your place (A3)

    /// The scroll view PDFView keeps inside itself.
    private var scrollView: NSScrollView? { documentView?.enclosingScrollView }

    /// The top-left corner of the area not covered by the toolbar, in view
    /// coordinates. Anchors are captured from and restored to this point.
    private var anchorTarget: CGPoint {
        let insets = safeAreaInsets
        let y = isFlipped ? bounds.minY + insets.top : bounds.maxY - insets.top
        return CGPoint(x: bounds.minX + insets.left, y: y)
    }

    /// Where reading is now: the page-space point at the top-left of the
    /// visible area. Nil without a document.
    public var currentAnchor: ReadingAnchor? {
        if let keptAnchor { return keptAnchor }
        return visibleAnchor
    }

    /// The anchor measured from the current scroll position, ignoring any
    /// anchor kept from the last restore.
    public var visibleAnchor: ReadingAnchor? {
        guard let document, document.pageCount > 0 else { return nil }
        var target = anchorTarget
        guard let page = page(for: target, nearest: true) else { return nil }
        let box = page.bounds(for: displayBox)
        // PDFKit maps points beside a page (in the gutter) inconsistently with
        // the reverse conversion, so measure from a point on the page itself.
        let pageRect = convert(box, from: page)
        if pageRect.width > 2, pageRect.height > 2 {
            target.x = min(max(target.x, pageRect.minX + 1), pageRect.maxX - 1)
            target.y = min(max(target.y, pageRect.minY + 1), pageRect.maxY - 1)
        }
        var point = convert(target, to: page)
        point.x = min(max(point.x, box.minX), box.maxX)
        point.y = min(max(point.y, box.minY), box.maxY)
        return ReadingAnchor(pageIndex: document.index(for: page), pointInPage: point, scale: scaleFactor)
    }

    /// Scrolls so that the anchor's point sits at the top-left of the visible
    /// area, as far as the document's edges allow. The page index is clamped
    /// to the document. The anchor's scale is not applied: zoom belongs to
    /// the view settings.
    public func restore(_ anchor: ReadingAnchor) {
        guard let document, document.pageCount > 0 else { return }
        let anchor = anchor.clamped(toPageCount: document.pageCount)
        guard let page = document.page(at: anchor.pageIndex) else { return }
        let wasAdjusting = isAdjustingGeometry
        isAdjustingGeometry = true
        defer { isAdjustingGeometry = wasAdjusting }
        // Paged modes show one page (or spread) at a time: bring it up first.
        if !displayMode.isContinuous, !visiblePages.contains(page) {
            go(to: page)
        }
        guard let scrollView else { return }
        observeClipView()
        let clip = scrollView.contentView
        let point = clip.convert(convert(anchor.pointInPage, from: page), from: self)
        let target = clip.convert(anchorTarget, from: self)
        var origin = clip.bounds.origin
        origin.x += point.x - target.x
        origin.y += point.y - target.y
        scroll(clip, to: origin, in: scrollView)
        var kept = anchor
        kept.scale = scaleFactor
        keptAnchor = kept
        // A command put the reader here; content moved after this is a
        // layout pass, not the user, even if they scrolled a moment ago.
        lastUserInput = -.infinity
    }

    /// Scrolls the clip view to `origin`, kept within the document.
    ///
    /// The bounds are clamped here rather than with `constrainBoundsRect`:
    /// PDFKit's clip view snaps that to rows in two-up layouts, which moved
    /// the reader by up to a line of text (measured on macOS 26).
    private func scroll(_ clip: NSClipView, to origin: CGPoint, in scrollView: NSScrollView) {
        var origin = origin
        let visible = clip.bounds.size
        if let documentFrame = clip.documentView?.frame {
            if documentFrame.width <= visible.width {
                // Narrower than the view: PDFKit centres it; leave x alone.
                origin.x = clip.bounds.origin.x
            } else {
                origin.x = min(max(origin.x, documentFrame.minX), documentFrame.maxX - visible.width)
            }
            // The content insets (the toolbar above, in document points) can
            // be scrolled into, so the first page's top shows below the toolbar.
            let ratio = clip.frame.height > 0 ? clip.bounds.height / clip.frame.height : 1
            let top = scrollView.contentInsets.top * ratio
            let bottom = scrollView.contentInsets.bottom * ratio
            let lowest = documentFrame.minY - (clip.isFlipped ? top : bottom)
            let highest = documentFrame.maxY - visible.height + (clip.isFlipped ? bottom : top)
            if highest <= lowest {
                origin.y = clip.bounds.origin.y
            } else {
                origin.y = min(max(origin.y, lowest), highest)
            }
        }
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }

    /// Runs `body`, which changes the geometry (zoom, size, layout or
    /// rotation), then puts the reader back where they were. Nested calls
    /// restore once, at the end of the outermost.
    public func preservingAnchor(_ body: () -> Void) {
        guard document != nil, !isAdjustingGeometry else {
            body()
            return
        }
        let anchor = currentAnchor
        isAdjustingGeometry = true
        body()
        layoutDocumentView()
        // Settle the scrollers now. A change can briefly make the document
        // wider than the view; the horizontal scroller that then appears
        // would otherwise go away on the next pass and shift the content by
        // its height, after the anchor was restored.
        scrollView?.tile()
        isAdjustingGeometry = false
        if let anchor { restore(anchor) }
    }

    /// Re-assigns the same document, keeping the place and zoom. Another view
    /// on the shared `PDFDocument` that changed an annotation leaves this one
    /// stale until it does (M0b Q7: five cheaper refreshes don't work).
    public func rebindDocument() {
        guard let document else { return }
        let anchor = currentAnchor
        // show(_:) keeps the zoom mode but fits against the first page; put
        // back the page the fit modes measured, so pages of other sizes don't
        // change the zoom on every annotation change.
        let reference = fitReferencePageIndex
        let selected = selectedAnnotation
        show(nil)
        show(document)
        if let selected, selected.page?.document === document { selectAnnotation(selected) }
        if reference != fitReferencePageIndex {
            fitReferencePageIndex = reference
            applyZoom()
        }
        layoutDocumentView()
        if let anchor { restore(anchor) }
    }

    /// The anchor that shows a page from its visual top-left corner, taking
    /// the page's rotation into account.
    public func topAnchor(forPageAt index: Int) -> ReadingAnchor? {
        guard let page = document?.page(at: index) else { return nil }
        let box = page.bounds(for: displayBox)
        let corner: CGPoint = switch ViewSettings.normalized(page.rotation) {
        case 90: CGPoint(x: box.minX, y: box.minY)
        case 180: CGPoint(x: box.maxX, y: box.minY)
        case 270: CGPoint(x: box.maxX, y: box.maxY)
        default: CGPoint(x: box.minX, y: box.maxY)
        }
        return ReadingAnchor(pageIndex: index, pointInPage: corner, scale: scaleFactor)
    }

    /// The anchor for a PDF destination. Unspecified coordinates (a `/Fit`
    /// destination, say) fall back to the page's top-left corner.
    public func anchor(for destination: PDFDestination) -> ReadingAnchor? {
        guard let document, let page = destination.page else { return nil }
        let index = document.index(for: page)
        guard index != NSNotFound, var anchor = topAnchor(forPageAt: index) else { return nil }
        let box = page.bounds(for: displayBox)
        let point = destination.point
        if point.x != kPDFDestinationUnspecifiedValue, point.x.isFinite {
            anchor.pointInPage.x = min(max(point.x, box.minX), box.maxX)
        }
        if point.y != kPDFDestinationUnspecifiedValue, point.y.isFinite {
            anchor.pointInPage.y = min(max(point.y, box.minY), box.maxY)
        }
        return anchor
    }

    /// Scrolls `selection` into the part of the view the toolbar doesn't
    /// cover, a third of the way down, as PDFKit's own `go(to:)` ignores the
    /// safe area.
    public func reveal(_ selection: PDFSelection) {
        guard let page = selection.pages.first, let scrollView else { return }
        let wasAdjusting = isAdjustingGeometry
        isAdjustingGeometry = true
        defer {
            isAdjustingGeometry = wasAdjusting
            // Where the result is shown is where reading is now.
            keptAnchor = visibleAnchor
        }
        if !displayMode.isContinuous, !visiblePages.contains(page) { go(to: page) }
        let rect = convert(selection.bounds(for: page), from: page)
        let insets = safeAreaInsets
        let visibleHeight = bounds.height - insets.top - insets.bottom
        let clip = scrollView.contentView
        // Where the selection's top edge should end up, in view coordinates.
        let offset = insets.top + visibleHeight / 3
        let current = isFlipped ? rect.minY : rect.maxY
        let wanted = isFlipped ? bounds.minY + offset : bounds.maxY - offset
        let from = clip.convert(CGPoint(x: rect.midX, y: current), from: self)
        let to = clip.convert(CGPoint(x: rect.midX, y: wanted), from: self)
        var origin = clip.bounds.origin
        origin.y += from.y - to.y
        let visibleWidth = bounds.width - insets.left - insets.right
        if rect.minX < bounds.minX + insets.left || rect.maxX > bounds.minX + insets.left + visibleWidth {
            let fromX = clip.convert(CGPoint(x: rect.midX, y: 0), from: self).x
            let toX = clip.convert(CGPoint(x: bounds.minX + insets.left + visibleWidth / 2, y: 0), from: self).x
            origin.x += fromX - toX
        }
        scroll(clip, to: origin, in: scrollView)
    }

    /// Watches the clip view: scrolls the user makes end the kept anchor;
    /// content moved by a layout pass is put back.
    private func observeClipView() {
        guard let clip = scrollView?.contentView, clip !== observedClipView else { return }
        if let observedClipView {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: observedClipView)
        }
        observedClipView = clip
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipBoundsDidChange(_:)), name: NSView.boundsDidChangeNotification, object: clip
        )
    }

    @objc private func clipBoundsDidChange(_ notification: Notification) {
        onVisibleAreaChange?()
        updateLinkOverlays()
        updateAnnotationOverlays()
        if isSelectionBarVisible { showSelectionBarIfNeeded() }
        guard !isAdjustingGeometry else { return }
        if isUserScrolling {
            keptAnchor = visibleAnchor
            return
        }
        // Not the user: a later layout pass moved the content, typically a
        // scroller appearing or going after a zoom or layout change (with
        // "Show scroll bars: Always", measured on macOS 26). Put the place
        // back; sub-point pixel snapping is left alone.
        if let keptAnchor, let visible = visibleAnchor, !visible.isSamePlace(as: keptAnchor, tolerance: 1) {
            restore(keptAnchor)
        }
    }

    // MARK: User input

    private static let userInputEvents: NSEvent.EventTypeMask = [
        .scrollWheel, .keyDown, .leftMouseDown, .leftMouseDragged, .leftMouseUp,
        .magnify, .smartMagnify, .swipe, .beginGesture, .endGesture,
    ]

    /// Keys that scroll or page even with ⌘ held (⌘↑ and ⌘↓ go to the
    /// start and end). Other ⌘ shortcuts are commands, which keep the place
    /// themselves.
    private static let navigationKeyCodes: Set<UInt16> = [115, 116, 119, 121, 123, 124, 125, 126]

    /// True for a short while after the user acted on this view, so the
    /// scrolls that follow are taken as theirs.
    private var isUserScrolling: Bool {
        ProcessInfo.processInfo.systemUptime - lastUserInput < 0.5
    }

    /// Records that the user scrolled, clicked or typed in the view. The event
    /// monitor calls this; tests call it to stand in for an event.
    public func noteUserInput() {
        lastUserInput = ProcessInfo.processInfo.systemUptime
    }

    private func noteInputIfMine(_ event: NSEvent) {
        guard let window, event.window === window, !window.inLiveResize else { return }
        switch event.type {
        case .keyDown:
            // Only keys typed into the reading area (not the search field).
            guard let responder = window.firstResponder as? NSView, responder === self || responder.isDescendant(of: self) else { return }
            if event.modifierFlags.contains(.command), !Self.navigationKeyCodes.contains(event.keyCode) { return }
        default:
            let location = convert(event.locationInWindow, from: nil)
            guard bounds.contains(location) else { return }
        }
        noteUserInput()
    }

    // MARK: Escape

    /// PDFView consumes Escape itself, so it never reaches the window's
    /// commands; link focus ends first, then the owner gets it.
    public override func cancelOperation(_ sender: Any?) {
        if isLinkFocusActive {
            endLinkFocus()
            return
        }
        if isSelectionBarVisible {
            hideSelectionBar()
            return
        }
        if selectedAnnotation != nil {
            selectAnnotation(nil)
            return
        }
        if onCancel?() == true { return }
        super.cancelOperation(sender)
    }

    public override func keyDown(with event: NSEvent) {
        if handleLinkFocusKey(event) { return }
        if handleFormKey(event) { return }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 51 || event.keyCode == 117, modifiers.isEmpty, selectedAnnotation != nil, onDeleteKey?() == true {
            return
        }
        if event.keyCode == 53, modifiers.isEmpty {
            cancelOperation(nil)
            return
        }
        super.keyDown(with: event)
    }

    // MARK: Copy (B6)

    /// Copying is allowed unless the document's permissions forbid it.
    /// PDFKit reports `allowsCopying` as true once the owner password is given.
    public var isCopyAllowed: Bool {
        document?.allowsCopying ?? false
    }

    public override func copy(_ sender: Any?) {
        guard isCopyAllowed else {
            onCopyBlocked?()
            return
        }
        super.copy(sender)
    }

    // Every other way text leaves the view respects the same restriction:
    // Services (which includes Search With Google), Translate, Look Up and
    // dragging.

    public override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        guard isCopyAllowed else { return nil }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    /// PDFView implements this privately; it is how Services and Translate
    /// read the selection. Replaced so that the restriction applies.
    @objc(writeSelectionToPasteboard:types:)
    public func writeSelection(to pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard isCopyAllowed, let text = currentSelection?.string, !text.isEmpty,
              types.contains(.string)
        else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    public override func quickLook(with event: NSEvent) {
        // Force-click and three-finger tap Look Up. Over any link it never
        // reaches PDFKit; an internal one previews instead.
        if handleLookUpOverLink(at: convert(event.locationInWindow, from: nil)) { return }
        guard isCopyAllowed else { return }
        super.quickLook(with: event)
    }

    /// What a drag of the selection may do. PDFView is not a drag source
    /// today (checked on macOS 26), so this only guards a future one.
    public var selectionDragOperations: NSDragOperation {
        isCopyAllowed ? .copy : []
    }

    // MARK: Context menu

    /// The reading commands for the context menu, supplied by the window so
    /// that they change the window's settings rather than PDFView's own
    /// display mode behind its back.
    public var contextMenuItems: () -> [NSMenuItem] = { [] }
    private var ownContextMenuItems: Set<ObjectIdentifier> = []

    /// Replaces PDFKit's menu, whose layout items (Two Pages, Automatically
    /// Resize…) bypass the view settings.
    public override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(title: "")
        let point = convert(event.locationInWindow, from: nil)
        if let page = page(for: point, nearest: true) {
            contextClickLocation = (page, convert(point, to: page))
        }
        let annotation = selectableAnnotation(at: point)
        if let annotation { selectAnnotation(annotation) }
        let annotationItems = annotationContextMenuItems(annotation)
        annotationItems.forEach(menu.addItem)
        if !annotationItems.isEmpty { menu.addItem(.separator()) }
        let copy = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)
        let reading = contextMenuItems()
        if !reading.isEmpty {
            menu.addItem(.separator())
            reading.forEach(menu.addItem)
        }
        if !isCopyAllowed {
            menu.allowsContextMenuPlugIns = false
            menu.automaticallyInsertsWritingToolsItems = false
        }
        ownContextMenuItems = Set(menu.items.map(ObjectIdentifier.init))
        return menu
    }

    /// AppKit and PDFKit add Look Up, Translate, Search With Google and
    /// Services as the menu opens; on a copy-restricted document only our
    /// own items stay.
    public override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        // PDFKit's "Open Link" calls NSWorkspace directly (M0b Q2).
        for item in menu.items.reversed() where item.action == Self.openRepresentedLinkSelector {
            menu.removeItem(item)
        }
        guard !isCopyAllowed else { return }
        for item in menu.items.reversed() where !ownContextMenuItems.contains(ObjectIdentifier(item)) {
            menu.removeItem(item)
        }
    }

    // MARK: Opening dropped files

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        Self.pdfURLs(on: sender.draggingPasteboard).isEmpty ? super.draggingEntered(sender) : .copy
    }

    public override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        Self.pdfURLs(on: sender.draggingPasteboard).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = Self.pdfURLs(on: sender.draggingPasteboard)
        guard !urls.isEmpty, let onOpenFiles else { return super.performDragOperation(sender) }
        onOpenFiles(urls)
        return true
    }

    /// The PDF file URLs on a drag pasteboard.
    public static func pdfURLs(on pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.pdf.identifier],
        ]
        return pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }
}

extension ReaderPDFView: NSDraggingSource {
    public func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        selectionDragOperations
    }
}

private extension PDFDisplayMode {
    var isContinuous: Bool { self == .singlePageContinuous || self == .twoUpContinuous }
}

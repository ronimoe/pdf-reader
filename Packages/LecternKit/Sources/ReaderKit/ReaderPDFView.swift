import AppKit
import PDFKit
import ReaderCore
import UniformTypeIdentifiers

/// The reading surface. Later milestones add link interception, anchors and
/// keyboard link focus here; this is the only type that subclasses PDFView.
///
/// The view owns the zoom mode so that the fit modes can be recomputed when
/// its size changes. Everything else in `ViewSettings` is applied by `apply`.
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

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var document: PDFDocument? {
        didSet {
            fitReferencePageIndex = 0
            applyZoom()
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

    /// Applies the layout and zoom in `settings`, keeping the current page in
    /// view. Rotation lives in the document model and is applied by its owner,
    /// which then calls this to re-fit.
    public func apply(_ settings: ViewSettings, hints: DocumentLayoutHints) {
        let page = currentPage
        withZoomApplied {
            displayMode = Self.displayMode(pages: settings.pages, scrolling: settings.scrolling)
            displaysAsBook = settings.effectiveCoverPageAlone(hints: hints)
            displaysRTL = settings.effectiveRightToLeft(hints: hints)
            layoutDocumentView()
        }
        setZoomMode(settings.zoom)
        if let page { go(to: page) }
    }

    // MARK: Zoom

    public func setZoomMode(_ mode: ZoomMode) {
        zoomMode = mode
        if mode.isFit, let document, let page = currentPage {
            fitReferencePageIndex = document.index(for: page)
        }
        applyZoom()
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

    private func withZoomApplied(_ body: () -> Void) {
        let wasApplying = isApplyingZoom
        isApplyingZoom = true
        body()
        isApplyingZoom = wasApplying
    }

    @objc private func scaleDidChange(_ notification: Notification) {
        guard !isApplyingZoom, document != nil else { return }
        zoomMode = .scale(scaleFactor)
        onUserZoom?(scaleFactor)
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refit(force: false)
    }

    public override func layout() {
        super.layout()
        // Safe-area changes (toolbar shown or hidden, full screen) arrive as
        // layout passes without a frame change.
        refit(force: false)
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

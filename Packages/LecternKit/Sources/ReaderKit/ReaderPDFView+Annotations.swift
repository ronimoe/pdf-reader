import AppKit
import PDFKit
import ReaderCore

/// What the selection control and the Annotate menu do with selected text (B4, Journey C).
public enum MarkupAction: String, Sendable, CaseIterable {
    case highlight, underline, strikeOut, note

    public var title: String {
        switch self {
        case .highlight: "Highlight"
        case .underline: "Underline"
        case .strikeOut: "Strike Through"
        case .note: "Note"
        }
    }

    public var symbolName: String {
        switch self {
        case .highlight: "highlighter"
        case .underline: "underline"
        case .strikeOut: "strikethrough"
        case .note: "text.bubble"
        }
    }
}

extension ReaderPDFView {
    // MARK: Hit testing

    /// The topmost annotation the reader can select under `point` (view coordinates): markup,
    /// notes and other listed kinds, never links, form widgets or popups. Text markup is hit on
    /// its quadrilaterals, so the gaps between highlighted lines stay free for selecting text.
    public func selectableAnnotation(at point: CGPoint) -> PDFAnnotation? {
        guard document != nil, let page = page(for: point, nearest: false) else { return nil }
        let pagePoint = convert(point, to: page)
        for annotation in page.annotations.reversed() {
            guard let type = annotation.type, AnnotationKindName.isListed(subtype: type) else { continue }
            if Self.hitRects(of: annotation).contains(where: { $0.insetBy(dx: -2, dy: -2).contains(pagePoint) }) {
                return annotation
            }
        }
        return nil
    }

    /// The form widget under `point`, if any (A5).
    public func widget(at point: CGPoint) -> PDFAnnotation? {
        guard document != nil, let page = page(for: point, nearest: false) else { return nil }
        let pagePoint = convert(point, to: page)
        return page.annotations.last { $0.type == "Widget" && $0.bounds.contains(pagePoint) }
    }

    /// The rectangles that count as the annotation, in page space: each quadrilateral of text
    /// markup (PDFKit gives them relative to the bounds' origin), otherwise the bounds.
    public static func hitRects(of annotation: PDFAnnotation) -> [CGRect] {
        let bounds = annotation.bounds
        let points = (annotation.quadrilateralPoints ?? []).map { $0.pointValue }
        guard ["Highlight", "Underline", "StrikeOut", "Squiggly"].contains(annotation.type ?? ""), points.count >= 4, points.count % 4 == 0 else {
            return [bounds]
        }
        return stride(from: 0, to: points.count, by: 4).map { start in
            let quad = points[start..<start + 4]
            let xs = quad.map(\.x), ys = quad.map(\.y)
            return CGRect(x: bounds.minX + xs.min()!, y: bounds.minY + ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
    }

    // MARK: Selecting an annotation

    /// Selects `annotation` (or clears the selection): it gets an outline drawn over the view,
    /// never into the document, and VoiceOver hears what it is.
    public func selectAnnotation(_ annotation: PDFAnnotation?) {
        guard annotation !== selectedAnnotation else {
            updateAnnotationOverlays()
            return
        }
        selectedAnnotation = annotation
        if annotation != nil { hideSelectionBar() }
        updateAnnotationOverlays()
        onAnnotationSelectionChange?(annotation)
    }

    // MARK: Clicks (called from the mouse overrides)

    /// A mouse-down not on a link. Returns true if it was handled and PDFKit must not see it.
    func handleAnnotationMouseDown(_ event: NSEvent, at point: CGPoint) -> Bool {
        pendingAnnotationClick = nil
        if widget(at: point) != nil {
            // Forms are read-only (A5): no field ever gets focus or toggles. isReadOnly is never
            // set, since PDFKit writes it into the file (M0b Q3).
            window?.makeFirstResponder(self)
            hideSelectionBar()
            return true
        }
        guard let annotation = selectableAnnotation(at: point) else {
            if selectedAnnotation != nil { selectAnnotation(nil) }
            return false
        }
        pendingAnnotationClick = PendingAnnotationClick(annotation: annotation, start: point, clickCount: event.clickCount)
        // Markup sits on text, so the press may still turn into a text selection: PDFKit sees it,
        // and the click selects the annotation only if the pointer doesn't move. Notes and other
        // shapes are ours alone: PDFKit would open a note's popup, which changes the document.
        if ["Highlight", "Underline", "StrikeOut", "Squiggly"].contains(annotation.type ?? "") {
            return false
        }
        window?.makeFirstResponder(self)
        return true
    }

    func handleAnnotationMouseDragged(at point: CGPoint) {
        guard let pending = pendingAnnotationClick else { return }
        if hypot(point.x - pending.start.x, point.y - pending.start.y) > 3 {
            pendingAnnotationClick = nil
        }
    }

    /// A mouse-up. Returns true if it completed a click on an annotation.
    @discardableResult
    func handleAnnotationMouseUp() -> Bool {
        guard let pending = pendingAnnotationClick else {
            showSelectionBarIfNeeded()
            return false
        }
        pendingAnnotationClick = nil
        clearSelection()
        selectAnnotation(pending.annotation)
        onAnnotationClick?(pending.annotation, pending.clickCount)
        return true
    }

    // MARK: Keyboard

    /// Tab and Shift-Tab never reach PDFKit while the document has form fields: they move
    /// between the window's controls instead, so no field can take focus (A5, M0b Q3).
    func handleFormKey(_ event: NSEvent) -> Bool {
        guard event.keyCode == 48, documentHasFormFields else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers.subtracting(.shift).isEmpty else { return false }
        if modifiers.contains(.shift) {
            window?.selectPreviousKeyView(self)
        } else {
            window?.selectNextKeyView(self)
        }
        return true
    }

    /// True when the catalog's AcroForm has fields, or any page has a Widget annotation (some
    /// files have widgets without `/Fields`). Read from CoreGraphics' dictionaries, so no
    /// `PDFPage` is created; worked out once per document.
    public var documentHasFormFields: Bool {
        if let known = formFieldsKnown { return known }
        guard let reference = document?.documentRef else { return false }
        let has = Self.catalogHasFields(reference) || Self.pagesHaveWidgets(reference)
        formFieldsKnown = has
        return has
    }

    static func catalogHasFields(_ reference: CGPDFDocument) -> Bool {
        guard let catalog = reference.catalog else { return false }
        var acroForm: CGPDFDictionaryRef?
        var fields: CGPDFArrayRef?
        return CGPDFDictionaryGetDictionary(catalog, "AcroForm", &acroForm) && acroForm.map { CGPDFDictionaryGetArray($0, "Fields", &fields) } == true
            && fields.map { CGPDFArrayGetCount($0) > 0 } == true
    }

    static func pagesHaveWidgets(_ reference: CGPDFDocument) -> Bool {
        guard reference.numberOfPages > 0 else { return false }
        for number in 1...reference.numberOfPages {
            guard let dictionary = reference.page(at: number)?.dictionary else { continue }
            var annots: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(dictionary, "Annots", &annots), let annots else { continue }
            for index in 0..<CGPDFArrayGetCount(annots) {
                var annotation: CGPDFDictionaryRef?
                var subtype: UnsafePointer<CChar>?
                if CGPDFArrayGetDictionary(annots, index, &annotation), let annotation,
                   CGPDFDictionaryGetName(annotation, "Subtype", &subtype), let subtype, String(cString: subtype) == "Widget" {
                    return true
                }
            }
        }
        return false
    }

    // MARK: The selection control (Journey C)

    /// Shows the control near the selected text, unless the user is still dragging or nothing
    /// is selected. Called after a mouse-up and when the selection changes otherwise.
    public func showSelectionBarIfNeeded() {
        guard showsSelectionBar, NSEvent.pressedMouseButtons & 1 == 0,
              let selection = currentSelection, let text = selection.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let page = selection.pages.first
        else {
            hideSelectionBar()
            return
        }
        let lineRect = convert(selection.selectionsByLine().first?.bounds(for: page) ?? selection.bounds(for: page), from: page)
        selectionBar.markupColor = markupColor
        let size = selectionBar.preferredSize
        let visible = unobscuredRect
        var origin = CGPoint(x: lineRect.minX, y: isFlipped ? lineRect.minY - size.height - 6 : lineRect.maxY + 6)
        let above = isFlipped ? origin.y >= visible.minY : origin.y + size.height <= visible.maxY
        if !above {
            // No room above the first line: show it below the selection.
            let whole = convert(selection.bounds(for: page), from: page)
            origin.y = isFlipped ? whole.maxY + 6 : whole.minY - size.height - 6
        }
        origin.x = min(max(origin.x, visible.minX + 4), max(visible.minX + 4, visible.maxX - size.width - 4))
        origin.y = min(max(origin.y, visible.minY + 4), max(visible.minY + 4, visible.maxY - size.height - 4))
        selectionBar.frame = CGRect(origin: origin, size: size)
        if selectionBar.isHidden {
            selectionBar.isHidden = false
            NSAccessibility.post(element: selectionBar, notification: .created)
        }
    }

    public func hideSelectionBar() {
        selectionBar.isHidden = true
    }

    public var isSelectionBarVisible: Bool { !selectionBar.isHidden }

    /// Not main-actor isolated: PDFKit posts from wherever it changed the selection, and its
    /// background work must never trap here (the M2 hotfix). The work hops to the main thread.
    @objc nonisolated func selectionDidChange(_ notification: Notification) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { selectionChanged() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.selectionChanged() } }
        }
    }

    private func selectionChanged() {
        // While the user drags, the selection changes continuously: the control waits for the
        // mouse-up (Journey C, "doesn't appear while dragging").
        if NSEvent.pressedMouseButtons & 1 != 0 || currentSelection == nil {
            hideSelectionBar()
        } else {
            showSelectionBarIfNeeded()
        }
    }

    // MARK: Overlays

    func updateAnnotationOverlays() {
        guard let annotation = selectedAnnotation, let page = annotation.page, page.document === document else {
            annotationOutline.isHidden = true
            return
        }
        let rect = convert(annotation.bounds, from: page).insetBy(dx: -3, dy: -3)
        annotationOutline.frame = rect
        annotationOutline.isHidden = false
        annotationOutline.label = Self.accessibilityDescription(of: annotation)
        if !selectionBar.isHidden, currentSelection == nil { hideSelectionBar() }
    }

    /// "Highlight, Yellow: the highlighted words. Comment: …" for VoiceOver.
    public static func accessibilityDescription(of annotation: PDFAnnotation) -> String {
        let kind = AnnotationKindName.name(forSubtype: annotation.type ?? "")
        var parts = [kind]
        if let color = annotation.color.usingColorSpace(.sRGB) {
            parts[0] += ", " + AnnotationColorPreset.describe(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent)
        }
        if let contents = annotation.contents, !contents.isEmpty {
            parts.append((annotation.type == "Text" ? "Note: " : "Comment: ") + contents)
        }
        return parts.joined(separator: ". ")
    }
}

struct PendingAnnotationClick {
    let annotation: PDFAnnotation
    let start: CGPoint
    let clickCount: Int
}

/// The outline around the selected annotation: drawn over the view, never into the document, and
/// a dashed shape as well as a colour (Rule 8).
final class AnnotationOutlineView: NSView {
    var label = "" {
        didSet { setAccessibilityLabel(label) }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityRoleDescription("selected annotation")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)
        path.lineWidth = 2
        path.setLineDash([5, 3], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The small control that appears next to selected text: Highlight, Underline, Strike Through,
/// Note, and the colour. Non-modal; it never takes keyboard focus from the page, and Escape hides
/// it (Journey C).
public final class SelectionActionBar: NSView {
    public var onAction: ((MarkupAction) -> Void)?
    public var onColor: ((AnnotationColorPreset) -> Void)?
    public var markupColor: AnnotationColorPreset = .default {
        didSet { updateColorButton() }
    }

    private let background = NSVisualEffectView()
    private let stack = NSStackView()
    public private(set) var actionButtons: [MarkupAction: NSButton] = [:]
    public let colorButton = NSPopUpButton(frame: .zero, pullsDown: true)

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
        background.material = .popover
        background.blendingMode = .withinWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor.separatorColor.cgColor
        addSubview(background)
        background.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 4, bottom: 3, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
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
        for action in MarkupAction.allCases {
            let button = NSButton(image: NSImage(systemSymbolName: action.symbolName, accessibilityDescription: action.title) ?? NSImage(), target: self, action: #selector(actionClicked(_:)))
            button.bezelStyle = .accessoryBarAction
            button.isBordered = false
            button.toolTip = action.title
            button.setAccessibilityLabel(action.title)
            button.refusesFirstResponder = true
            button.tag = MarkupAction.allCases.firstIndex(of: action)!
            actionButtons[action] = button
            stack.addArrangedSubview(button)
        }
        colorButton.isBordered = false
        colorButton.refusesFirstResponder = true
        colorButton.toolTip = "Colour"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "", action: nil, keyEquivalent: ""))
        for (index, preset) in AnnotationColorPreset.allCases.enumerated() {
            let item = NSMenuItem(title: preset.name, action: #selector(colorChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.image = Self.swatch(preset)
            menu.addItem(item)
        }
        colorButton.menu = menu
        stack.addArrangedSubview(colorButton)
        updateColorButton()
        // The bar is placed by its frame: start at the size its buttons need, so an empty frame
        // never conflicts with them.
        setFrameSize(preferredSize)
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Annotate selection")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The size the buttons need.
    public var preferredSize: NSSize { stack.fittingSize }

    public override var acceptsFirstResponder: Bool { false }
    // A click on the bar must not reach the page underneath, nor make the window key-cycle.
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func updateColorButton() {
        let first = colorButton.menu?.item(at: 0)
        first?.image = Self.swatch(markupColor)
        first?.title = ""
        colorButton.setAccessibilityLabel("Colour: \(markupColor.name)")
        for item in colorButton.menu?.items.dropFirst() ?? [] {
            item.state = item.tag == AnnotationColorPreset.allCases.firstIndex(of: markupColor) ? .on : .off
        }
    }

    @objc private func actionClicked(_ sender: NSButton) {
        onAction?(MarkupAction.allCases[sender.tag])
    }

    @objc private func colorChosen(_ sender: NSMenuItem) {
        let preset = AnnotationColorPreset.allCases[sender.tag]
        markupColor = preset
        onColor?(preset)
    }

    /// Presses an action as a click would, for keyboard users' menu equivalents and tests.
    public func perform(_ action: MarkupAction) {
        onAction?(action)
    }

    /// A round swatch for a colour preset; menus show its name beside it (Rule 8).
    public static func swatch(_ preset: AnnotationColorPreset) -> NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            let c = preset.rgb
            NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1).setFill()
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            path.fill()
            NSColor.black.withAlphaComponent(0.25).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            return true
        }
        image.accessibilityDescription = preset.name
        return image
    }
}

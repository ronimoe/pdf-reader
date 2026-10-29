import AppKit
import PDFKit
import Persistence
import ReaderCore
import ReaderKit
import Testing
@testable import Lectern

/// Parent suite for M3 (links, previews, split). Serialized: the click and
/// key tests share the app's event queue and the NSWorkspace tripwire.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct M3Tests {}

/// The M3 fixture: eight pages, with every kind of link on page 1, links
/// back from page 5, named destinations and an outline. External targets
/// are inert (`.invalid` hosts, unregistered schemes, paths that don't exist).
nonisolated enum LinkFixture {
    struct Spec: Sendable {
        let text: String
        let entry: String
        /// The expected `LinkTarget.kind`.
        let kind: String
    }

    /// Page objects are 3...10, so page index i is object 3 + i.
    static let specs: [Spec] = [
        Spec(text: "Figure 3", entry: "/A << /S /GoTo /D [6 0 R /XYZ 72 500 null] >>", kind: "destination(3)"),
        Spec(text: "Section 2", entry: "/Dest (sec2)", kind: "destination(4)"),
        Spec(text: "Table 1", entry: "/A << /S /GoTo /D (tab1) >>", kind: "destination(5)"),
        Spec(text: "Appendix", entry: "/Dest [5 0 R /Fit]", kind: "destination(2)"),
        Spec(text: "Fit width", entry: "/A << /S /GoTo /D [7 0 R /FitH 400] >>", kind: "destination(4)"),
        Spec(text: "Fit rectangle", entry: "/A << /S /GoTo /D [7 0 R /FitR 72 72 300 300] >>", kind: "destination(4)"),
        Spec(text: "No position", entry: "/A << /S /GoTo /D [8 0 R /XYZ null null null] >>", kind: "destination(5)"),
        Spec(text: "Website", entry: "/A << /S /URI /URI (https://lectern-probe.invalid/page) >>", kind: "web(https://lectern-probe.invalid/page)"),
        Spec(text: "Custom scheme", entry: "/A << /S /URI /URI (lectern-probe-unhandled://uri-link) >>", kind: "otherScheme(lectern-probe-unhandled://uri-link)"),
        Spec(text: "Other file", entry: "/A << /S /GoToR /F (/nonexistent/lectern-probe.pdf) /D [0 /Fit] >>", kind: "blocked(GoToR)"),
        Spec(text: "Launch app", entry: "/A << /S /Launch /F (/nonexistent/lectern-probe.app) >>", kind: "blocked(Launch)"),
        Spec(text: "Run script", entry: "/A << /S /JavaScript /JS (var lecternProbe = 1;) >>", kind: "blocked(JavaScript)"),
        Spec(text: "Submit form", entry: "/A << /S /SubmitForm /F << /FS /URL /F (https://lectern-probe.invalid/submit) >> /Flags 4 >>", kind: "blocked(SubmitForm)"),
        Spec(text: "Next page", entry: "/A << /S /Named /N /NextPage >>", kind: "named(NextPage)"),
    ]

    static func index(_ text: String) -> Int { specs.firstIndex { $0.text == text }! }

    /// Page 1's link rectangles, top to bottom.
    static func rect(_ index: Int) -> CGRect {
        CGRect(x: 72, y: 740 - index * 40, width: 260, height: 22)
    }

    /// Page 5's links: back to the start, and on to Figure 3.
    static let page5Links: [Spec] = [
        Spec(text: "Back to start", entry: "/A << /S /GoTo /D [3 0 R /XYZ 0 792 null] >>", kind: "destination(0)"),
        Spec(text: "See Figure 3", entry: "/A << /S /GoTo /D [6 0 R /XYZ 72 500 null] >>", kind: "destination(3)"),
    ]

    static func make(openAction: String? = nil) -> Data {
        var objects: [Int: String] = [:]
        let pageCount = 8
        var catalog = "<< /Type /Catalog /Pages 2 0 R /Names << /Dests 30 0 R >> /Outlines 40 0 R"
        if let openAction { catalog += " /OpenAction \(openAction)" }
        objects[1] = catalog + " >>"
        objects[2] = "<< /Type /Pages /Kids [\((0..<pageCount).map { "\(3 + $0) 0 R" }.joined(separator: " "))] /Count \(pageCount) >>"
        objects[19] = SpikeRawPDF.helvetica
        for index in 0..<pageCount {
            var annots = ""
            if index == 0 { annots = " /Annots [\((0..<specs.count).map { "\(50 + $0) 0 R" }.joined(separator: " "))]" }
            if index == 4 { annots = " /Annots [80 0 R 81 0 R]" }
            objects[3 + index] = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents \(11 + index) 0 R /Resources << /Font << /F1 19 0 R >> >>\(annots) >>"
            var ops = ""
            if index == 0 {
                for (offset, spec) in specs.enumerated() {
                    let r = rect(offset)
                    ops += "BT /F1 14 Tf 74 \(Int(r.minY) + 6) Td (\(spec.text)) Tj ET\n"
                }
            } else {
                ops += "BT /F1 18 Tf 72 740 Td (Page \(index + 1) heading) Tj ET\n"
                for line in 0..<20 {
                    ops += "BT /F1 12 Tf 72 \(700 - line * 30) Td (Page \(index + 1) line \(line) of ordinary text) Tj ET\n"
                }
                if index == 4 {
                    ops += "BT /F1 14 Tf 74 106 Td (Back to start) Tj ET\nBT /F1 14 Tf 74 66 Td (See Figure 3) Tj ET\n"
                }
            }
            objects[11 + index] = SpikeRawPDF.stream(ops)
        }
        for (offset, spec) in specs.enumerated() {
            let r = rect(offset)
            objects[50 + offset] = "<< /Type /Annot /Subtype /Link /Rect [\(Int(r.minX)) \(Int(r.minY)) \(Int(r.maxX)) \(Int(r.maxY))] /Border [0 0 0] \(spec.entry) >>"
        }
        objects[80] = "<< /Type /Annot /Subtype /Link /Rect [72 100 300 122] /Border [0 0 0] \(page5Links[0].entry) >>"
        objects[81] = "<< /Type /Annot /Subtype /Link /Rect [72 60 300 82] /Border [0 0 0] \(page5Links[1].entry) >>"
        objects[30] = "<< /Names [(sec2) [7 0 R /XYZ 0 600 null] (tab1) [8 0 R /XYZ 0 400 null]] >>"
        objects[40] = "<< /Type /Outlines /First 41 0 R /Last 42 0 R /Count 2 >>"
        objects[41] = "<< /Title (Start) /Parent 40 0 R /Next 42 0 R /Dest [3 0 R /XYZ 0 792 null] >>"
        objects[42] = "<< /Title (Results) /Parent 40 0 R /Prev 41 0 R /Dest [6 0 R /XYZ 0 700 null] >>"
        return SpikeRawPDF.build(objects: objects, root: 1).data
    }

    /// The bundled arXiv paper (CC BY 4.0, see Tests/Corpus/README.md).
    static func arxivPaper() throws -> Data {
        let bundle = Bundle(for: BundleMarker.self)
        let url = try #require(bundle.url(forResource: "arxiv-2310.12457v2", withExtension: "pdf"))
        return try Data(contentsOf: url)
    }
}

private final class BundleMarker {}

/// Hosts previews in an invisible window instead of a popover, and records
/// what was presented.
@MainActor
final class TestPreviewPresenter: LinkPreviewPresenting {
    private(set) var presented: [LinkPreviewController] = []
    private(set) var anchorRects: [NSRect] = []
    private var host: OffscreenHost?
    var current: LinkPreviewController? { host == nil ? nil : presented.last }

    func present(_ controller: LinkPreviewController, relativeTo rect: NSRect, of view: NSView) {
        if let current { dismiss(current) }
        presented.append(controller)
        anchorRects.append(rect)
        host = OffscreenHost(content: controller.view, size: controller.view.frame.size)
        controller.layoutAndShow()
    }

    func dismiss(_ controller: LinkPreviewController) {
        guard controller === current else { return }
        host?.close()
        host = nil
        controller.didClose()
    }
}

/// A reader window for one document, on a real screen but invisible and
/// click-through, with every way out of the app recorded instead of taken.
@MainActor
final class M3Harness {
    let document: ReaderDocument
    let controller: ReaderWindowController
    let presenter = RecordingPresenter()
    let previews = TestPreviewPresenter()
    let opener = RecordingURLOpener()
    let preferences = ReaderPreferences.ephemeral()

    convenience init(_ data: Data = LinkFixture.make(), size: NSSize = NSSize(width: 640, height: 880)) throws {
        try self.init(document: ReaderDocument.loaded(data), store: nil, size: size)
    }

    convenience init(file: URL, store: DocumentStateStore?, size: NSSize = NSSize(width: 640, height: 880)) throws {
        try self.init(document: ReaderDocument.opened(file), store: store, size: size)
    }

    init(document: ReaderDocument, store: DocumentStateStore?, size: NSSize) throws {
        WorkspaceTripwire.shared.install()
        WorkspaceTripwire.shared.reset()
        self.document = document
        controller = ReaderWindowController(
            document: document, passwordStore: InMemoryPasswordStore(), presenter: presenter, stateStore: store,
            previewPresenter: previews, urlOpener: opener, preferences: preferences
        )
        document.addWindowController(controller)
        let window = try #require(controller.window)
        // Never touch the user's saved window frame.
        window.setFrameAutosaveName("")
        window.setContentSize(size)
        // At the primary screen's origin, fully transparent and click-through
        // (see SpikeHosting): Synth's events then keep their coordinates.
        window.setFrameOrigin(NSScreen.screens.first?.frame.origin ?? .zero)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        controller.splitViewController.view.layoutSubtreeIfNeeded()
        Spin.runLoop(0.05)
    }

    func close() {
        controller.dismissPreview()
        controller.window?.orderOut(nil)
        document.close()
        #expect(WorkspaceTripwire.shared.calls.isEmpty, "NSWorkspace was asked to open: \(WorkspaceTripwire.shared.calls)")
    }

    var window: NSWindow { controller.window! }
    var primary: ReaderPane { controller.primaryPane }
    var view: ReaderPDFView { controller.primaryPane.view }
    var pdf: PDFDocument { view.document! }

    /// Page 1's link annotations, top to bottom (the fixture's order).
    func link(_ text: String, page: Int = 0) -> PDFAnnotation {
        let annotations = pdf.page(at: page)!.annotations.filter { $0.type == "Link" }
        let rect = page == 0 ? LinkFixture.rect(LinkFixture.index(text)) : CGRect(x: 72, y: text == "Back to start" ? 100 : 60, width: 228, height: 22)
        return annotations.first { $0.bounds.intersects(rect.insetBy(dx: 4, dy: 4)) }!
    }

    /// Shows page 1 at the top, where every fixture link is visible.
    func showFirstPage(in pane: ReaderPane? = nil) {
        let pane = pane ?? primary
        pane.view.restore(pane.view.topAnchor(forPageAt: 0)!)
        Spin.runLoop(0.05)
    }

    func center(of annotation: PDFAnnotation, in view: ReaderPDFView? = nil) -> CGPoint {
        let view = view ?? self.view
        return view.convert(CGPoint(x: annotation.bounds.midX, y: annotation.bounds.midY), from: annotation.page!)
    }

    func windowPoint(of annotation: PDFAnnotation, in view: ReaderPDFView? = nil) -> NSPoint {
        let view = view ?? self.view
        return view.convert(center(of: annotation, in: view), to: nil)
    }

    func click(_ annotation: PDFAnnotation, in view: ReaderPDFView? = nil) {
        Synth.click(at: windowPoint(of: annotation, in: view), in: window)
    }

    /// Previews `annotation` from `pane` the way the keyboard does, without
    /// depending on which links a narrow pane has in view.
    func preview(_ annotation: PDFAnnotation, from pane: ReaderPane? = nil) throws -> LinkPreviewController {
        let pane = pane ?? primary
        let target = try #require(ReaderKit.LinkClassifier.target(of: annotation))
        let destination = try #require(target.destination)
        let rect = pane.view.convert(annotation.bounds, from: annotation.page!)
        controller.showPreview(LinkPreviewRequest(destination: destination, linkText: ReaderPDFView.text(of: annotation), sourceRect: rect, trigger: .keyboard), from: pane)
        return try #require(previews.current)
    }

    func key(_ characters: String, _ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = []) {
        Synth.key(characters, keyCode: keyCode, in: window, modifiers: modifiers)
    }
}

/// The annotation effect layers PDFKit draws under a view's page views: how
/// many annotations the view shows (offscreen pixels don't include them,
/// M0b Q11).
@MainActor
func annotationLayerCount(_ view: PDFView) -> Int {
    var count = 0
    func walk(_ layer: CALayer) {
        if String(describing: type(of: layer)).contains("AnnotationEffect") { count += 1 }
        layer.sublayers?.forEach(walk)
    }
    func find(_ v: NSView) {
        if String(describing: type(of: v)) == "PDFPageView", let layer = v.layer { walk(layer) }
        v.subviews.forEach(find)
    }
    find(view)
    return count
}

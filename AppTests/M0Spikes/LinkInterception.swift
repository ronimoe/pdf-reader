import AppKit
import PDFKit

/// Prototype of the link layer for `ReaderPDFView` (architecture §4.4),
/// kept in the test target for M0b. It owns every click on a link
/// annotation: PDFKit's own mouse handling never sees it.

/// What a link does, classified for routing.
enum LinkTarget: Equatable {
    case destination(pageIndex: Int)
    case web(URL)              // http / https: open in the browser when allowed
    case otherScheme(URL)      // ask first
    case blocked(String)       // GoToR, Launch, SubmitForm, JavaScript, …: explain, do nothing
    case named(String)         // NextPage, Print, …
}

/// The seam through which a URL leaves the app. Production would wrap
/// `NSWorkspace.shared.open`; tests use a recorder.
protocol URLOpening: AnyObject {
    func open(_ url: URL)
}

final class RecordingOpener: URLOpening {
    private(set) var opened: [URL] = []
    func open(_ url: URL) { opened.append(url) }
}

enum LinkClassifier {
    static func classify(_ annotation: PDFAnnotation) -> LinkTarget? {
        guard annotation.type == "Link" else { return nil }
        if let action = annotation.action {
            // Classify by the PDF action type first: PDFKit exposes Launch as a
            // PDFActionURL with a nil URL, and SubmitForm / JavaScript as a
            // bare PDFAction.
            switch action.type {
            case "Launch", "SubmitForm", "JavaScript", "ImportData", "GoToE", "Hide", "Rendition", "Sound", "Movie":
                return .blocked(action.type)
            default:
                break
            }
            switch action {
            case let goTo as PDFActionGoTo:
                return destinationTarget(goTo.destination)
            case let url as PDFActionURL:
                guard let target = url.url else { return .blocked("URI without URL") }
                let scheme = target.scheme?.lowercased()
                return (scheme == "http" || scheme == "https") ? .web(target) : .otherScheme(target)
            case is PDFActionRemoteGoTo:
                return .blocked("GoToR")
            case let named as PDFActionNamed:
                return .named("\(named.name.rawValue)")
            case is PDFActionResetForm:
                return .blocked("ResetForm")
            default:
                return .blocked(action.type)
            }
        }
        if let destination = annotation.destination {
            return destinationTarget(destination)
        }
        // A link with neither action nor destination: never let PDFKit act on it.
        return .blocked("no action")
    }

    private static func destinationTarget(_ destination: PDFDestination) -> LinkTarget {
        guard let page = destination.page, let document = page.document else { return .blocked("dangling destination") }
        return .destination(pageIndex: document.index(for: page))
    }
}

final class InterceptingPDFView: PDFView {
    weak var opener: URLOpening?
    /// Policy for URLs; default denies everything.
    var allowURL: (URL) -> Bool = { _ in false }
    private(set) var routed: [LinkTarget] = []
    private(set) var history: [Int] = []
    private var pendingLink: LinkTarget?

    /// The link annotation under a window point, if any.
    func linkTarget(atWindowPoint point: NSPoint) -> LinkTarget? {
        let inView = convert(point, from: nil)
        guard let page = page(for: inView, nearest: false) else { return nil }
        guard let annotation = page.annotation(at: convert(inView, to: page)) else { return nil }
        return LinkClassifier.classify(annotation)
    }

    var eventLog: [String] = []

    override func mouseDown(with event: NSEvent) {
        let target = linkTarget(atWindowPoint: event.locationInWindow)
        eventLog.append("down at \(event.locationInWindow) target=\(String(describing: target))")
        if let target {
            pendingLink = target   // swallow: PDFKit never starts link tracking
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        eventLog.append("up at \(event.locationInWindow) pending=\(String(describing: pendingLink))")
        if let target = pendingLink {
            pendingLink = nil
            if linkTarget(atWindowPoint: event.locationInWindow) == target { route(target) }
            return
        }
        super.mouseUp(with: event)
    }

    /// PDFView's own context menu over a link has "Open Link", which opens
    /// the URL through the delegate or NSWorkspace without passing through
    /// mouseDown. Remove it; the reader adds its own routed item later.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event) else { return nil }
        for item in menu.items where item.action == NSSelectorFromString("openRepresentedLink:") {
            menu.removeItem(item)
        }
        return menu
    }

    /// Defence in depth: PDFKit's private menu action opens a represented URL
    /// with NSWorkspace directly, skipping the delegate. Same selector, so
    /// this replaces it for instances of this class.
    @objc(openRepresentedLink:)
    func lecternOpenRepresentedLink(_ sender: Any?) {
        guard let url = (sender as? NSMenuItem)?.representedObject as? URL else { return }
        let scheme = url.scheme?.lowercased()
        route(scheme == "http" || scheme == "https" ? .web(url) : .otherScheme(url))
    }

    func route(_ target: LinkTarget) {
        routed.append(target)
        switch target {
        case let .destination(pageIndex):
            if let current = currentPage, let document { history.append(document.index(for: current)) }
            if let page = document?.page(at: pageIndex) { go(to: page) }
        case let .web(url), let .otherScheme(url):
            if allowURL(url) { opener?.open(url) }
        case .blocked, .named:
            break
        }
    }
}

// MARK: - Probes of PDFKit's default behaviour

/// Records which PDFView entry points a click passes through, then lets
/// PDFKit carry on as normal.
final class ProbePDFView: PDFView {
    var performed: [String] = []
    var wentTo: [Int] = []
    var mouseDowns = 0
    var mouseUps = 0

    override func perform(_ action: PDFAction) {
        performed.append(action.type)
        super.perform(action)
    }

    override func go(to destination: PDFDestination) {
        if let page = destination.page, let document = page.document { wentTo.append(document.index(for: page)) }
        super.go(to: destination)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDowns += 1
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        mouseUps += 1
        super.mouseUp(with: event)
    }
}

final class ProbeViewDelegate: NSObject, PDFViewDelegate {
    var calls: [String] = []

    func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
        calls.append("willClickOnLink \(url.absoluteString)")
    }

    func pdfViewOpenPDF(_ sender: PDFView, forRemoteGoToAction action: PDFActionRemoteGoTo) {
        // `action.url` is declared non-optional but is nil when the document
        // has no file URL (loaded from data); touching it from Swift traps.
        let url = (action as NSObject).value(forKey: "URL") as? URL
        calls.append("openPDFForRemoteGoTo \(url?.path ?? "nil URL")")
    }

    func pdfViewPerformFind(_ sender: PDFView) { calls.append("performFind") }
    func pdfViewPerformGo(toPage sender: PDFView) { calls.append("performGoToPage") }
    func pdfViewPerformPrint(_ sender: PDFView) { calls.append("performPrint") }
}

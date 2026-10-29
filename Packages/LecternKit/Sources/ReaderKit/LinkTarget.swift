import AppKit
import PDFKit

/// What a link does, classified for routing (A4, architecture §4.4).
///
/// Links are classified by the PDF action's `type` string, never by the
/// Swift class PDFKit hands back: `Launch` arrives as a `PDFActionURL` with
/// no URL, `SubmitForm` and `JavaScript` as a bare `PDFAction`, and reading
/// `PDFActionRemoteGoTo.url` from Swift traps when the document has no file
/// URL (M0b Q2). Nothing here ever casts to `PDFActionRemoteGoTo`.
public enum LinkTarget {
    /// A place in this document: a `GoTo` action, an explicit or named
    /// destination (PDFKit resolves named destinations itself).
    case destination(PDFDestination)
    /// An `http` or `https` URI: opens in the default browser when clicked.
    case web(URL)
    /// A URI with any other scheme: asks first.
    case otherScheme(URL)
    /// A named viewer action (`NextPage`, `GoBack`…).
    case named(PDFActionNamedName)
    /// Never performed: `GoToR`, `Launch`, `SubmitForm`, `JavaScript`, and
    /// anything else. Carries the raw action type for the explanation.
    case blocked(actionType: String)

    /// True for a destination inside this document: the only kind of link
    /// that can be previewed (A3).
    public var isInternal: Bool {
        if case .destination = self { return true }
        return false
    }

    public var destination: PDFDestination? {
        if case let .destination(destination) = self { return destination }
        return nil
    }

    /// The URL a web or other-scheme link would open.
    public var url: URL? {
        switch self {
        case let .web(url), let .otherScheme(url): url
        default: nil
        }
    }

    /// A short, comparable description, for tests and logs.
    public var kind: String {
        switch self {
        case let .destination(destination):
            let page = destination.page.flatMap { page in page.document.map { $0.index(for: page) } } ?? -1
            return "destination(\(page))"
        case let .web(url): return "web(\(url.absoluteString))"
        case let .otherScheme(url): return "otherScheme(\(url.absoluteString))"
        case let .named(name): return "named(\(Self.description(of: name)))"
        case let .blocked(type): return "blocked(\(type))"
        }
    }

    /// The PDF name of a named action (`NextPage`…).
    public static func description(of name: PDFActionNamedName) -> String {
        switch name {
        case .nextPage: "NextPage"
        case .previousPage: "PrevPage"
        case .firstPage: "FirstPage"
        case .lastPage: "LastPage"
        case .goBack: "GoBack"
        case .goForward: "GoForward"
        case .goToPage: "GoToPage"
        case .find: "Find"
        case .print: "Print"
        case .zoomIn: "ZoomIn"
        case .zoomOut: "ZoomOut"
        default: "Named"
        }
    }
}

public enum LinkClassifier {
    /// The target of a link annotation, or nil if `annotation` isn't a link.
    public static func target(of annotation: PDFAnnotation) -> LinkTarget? {
        guard annotation.type == "Link" else { return nil }
        if let action = annotation.action { return target(of: action) }
        if let destination = annotation.destination { return target(of: destination) }
        // A link with neither: never let PDFKit act on it.
        return .blocked(actionType: "none")
    }

    public static func target(of action: PDFAction) -> LinkTarget {
        switch action.type {
        case "GoTo":
            guard let destination = (action as? PDFActionGoTo)?.destination else { return .blocked(actionType: "GoTo") }
            return target(of: destination)
        case "URI":
            guard let url = (action as? PDFActionURL)?.url else { return .blocked(actionType: "URI") }
            let scheme = url.scheme?.lowercased()
            return scheme == "http" || scheme == "https" ? .web(url) : .otherScheme(url)
        case "Named":
            guard let named = action as? PDFActionNamed else { return .blocked(actionType: "Named") }
            return .named(named.name)
        default:
            // GoToR, Launch, SubmitForm, JavaScript, ResetForm, ImportData,
            // GoToE, Hide, Rendition, Sound, Movie, Thread…
            return .blocked(actionType: action.type)
        }
    }

    public static func target(of destination: PDFDestination) -> LinkTarget {
        guard let page = destination.page, let document = page.document, document.index(for: page) != NSNotFound else {
            return .blocked(actionType: "GoTo")
        }
        return .destination(destination)
    }

    /// Whether a destination names a usable position. `/Fit`, `/FitH`,
    /// `/FitR`, `/XYZ null null` all arrive from PDFKit as an unspecified
    /// point (M0b Q7); the preview then shows the whole page.
    public static func hasPosition(_ destination: PDFDestination) -> Bool {
        let y = destination.point.y
        return y != kPDFDestinationUnspecifiedValue && y.isFinite
    }
}

/// Why a link was not followed, in words for the user (A4).
public struct BlockedLink: Equatable, Sendable {
    public let actionType: String
    public var title: String
    public var message: String

    public init(actionType: String) {
        self.actionType = actionType
        switch actionType {
        case "GoToR":
            title = "This link points to another file"
            message = "Links that open other PDF files aren’t followed. Open the other file yourself if you trust it."
        case "Launch":
            title = "This link would open an app or file"
            message = "Links that launch other apps or open files on this Mac are never followed."
        case "SubmitForm":
            title = "This link would send form data"
            message = "Links that submit a document’s form data over the network are never followed."
        case "JavaScript":
            title = "This link would run a script"
            message = "Scripts in documents are never run."
        default:
            title = "This link can’t be followed"
            message = "The link uses an action (\(actionType)) that isn’t supported."
        }
    }
}

/// The one way a URL leaves the app. Production uses `WorkspaceURLOpener`;
/// tests use a recorder, and the test host's default refuses everything.
@MainActor
public protocol URLOpening: AnyObject {
    func open(_ url: URL)
}

public final class WorkspaceURLOpener: URLOpening {
    public init() {}
    public func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

/// Records URLs instead of opening them.
public final class RecordingURLOpener: URLOpening {
    public private(set) var opened: [URL] = []
    public init() {}
    public func open(_ url: URL) { opened.append(url) }
}

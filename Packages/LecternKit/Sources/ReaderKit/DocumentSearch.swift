import AppKit
import PDFKit
import ReaderCore

/// One match, as listed in the sidebar (B8).
public final class SearchResult {
    public let selection: PDFSelection
    public let pageIndex: Int
    /// The match's range in its page's text, for the excerpt.
    let range: NSRange
    private weak var search: DocumentSearch?
    private var cachedExcerpt: (text: String, match: NSRange)?

    init(selection: PDFSelection, pageIndex: Int, range: NSRange, search: DocumentSearch) {
        self.selection = selection
        self.pageIndex = pageIndex
        self.range = range
        self.search = search
    }

    /// The text around the match, built the first time it's asked for so a
    /// search with thousands of results stays cheap.
    public var excerpt: (text: String, match: NSRange) {
        if let cachedExcerpt { return cachedExcerpt }
        let text = search?.text(ofPageAt: pageIndex) ?? ""
        let excerpt = range.location == NSNotFound
            ? (selection.string ?? "", NSRange(location: 0, length: (selection.string ?? "").utf16.count))
            : SearchText.excerpt(around: range, in: text)
        cachedExcerpt = excerpt
        return excerpt
    }
}

/// A full-text search over one document, using PDFKit's asynchronous find
/// (B8, architecture §4.6).
///
/// Measured on macOS 26: `beginFindString` returns at once and reports each
/// match on the main thread through `PDFDocumentDidFindMatch`, a page at a
/// time; the run loop keeps turning between pages (longest gap about 20 ms on
/// a 600-page document), so the UI never blocks. Results are delivered to
/// `onChange` at most every 100 ms.
///
/// PDFKit has no whole-word option; Whole Word filters the matches it finds.
public final class DocumentSearch {
    public let document: PDFDocument
    public private(set) var query = ""
    public private(set) var options = SearchOptions()
    public private(set) var results: [SearchResult] = []
    public private(set) var isSearching = false
    /// Pages finished so far, for the progress indicator.
    public private(set) var pagesSearched = 0
    /// Pages with no text layer, once the inventory has run.
    public var pagesWithoutText: Int? {
        didSet {
            // Nothing to search: say so at once instead of searching on.
            if summary.documentHasNoText, isSearching {
                cancelFind()
                pagesSearched = document.pageCount
                scheduleChange(now: true)
            } else {
                scheduleChange()
            }
        }
    }

    /// Called on the main thread when results, progress or state change.
    public var onChange: (() -> Void)?
    public var coalescingInterval: TimeInterval = 0.1

    private var pageTexts: [Int: NSString] = [:]
    /// The pending coalesced update. A run-loop timer, not `DispatchQueue.main.asyncAfter`: PDFKit
    /// posts a notification per match and per page, and on a long document those flood the main
    /// queue faster than it drains, so a block queued behind them ran only when the search ended
    /// (7.5 s on the 3,270-page manual, with the first match found after 0.4 s; M6). A timer fires
    /// between queue drains.
    private var changeTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    public init(document: PDFDocument) {
        self.document = document
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .PDFDocumentDidFindMatch, object: document, queue: .main) { [weak self] notification in
                let selection = notification.userInfo?["PDFDocumentFoundSelection"] as? PDFSelection
                nonisolated(unsafe) let found = selection
                MainActor.assumeIsolated { self?.didFind(found) }
            },
            center.addObserver(forName: .PDFDocumentDidEndPageFind, object: document, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.didEndPage() }
            },
            center.addObserver(forName: .PDFDocumentDidEndFind, object: document, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.didEnd() }
            },
        ]
    }

    isolated deinit {
        changeTimer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
        if document.isFinding { document.cancelFindString() }
    }

    public var summary: SearchSummary {
        SearchSummary(resultCount: results.count, isSearching: isSearching, pagesWithoutText: pagesWithoutText, pageCount: document.pageCount)
    }

    public var progress: Double {
        document.pageCount == 0 ? 1 : Double(pagesSearched) / Double(document.pageCount)
    }

    /// Starts searching for `query`, replacing any search in progress.
    public func start(_ query: String, options: SearchOptions) {
        cancelFind()
        self.query = query
        self.options = options
        results = []
        pagesSearched = 0
        guard !query.isEmpty, document.pageCount > 0 else {
            isSearching = false
            scheduleChange(now: true)
            return
        }
        isSearching = true
        document.beginFindString(query, withOptions: options.compareOptions)
        scheduleChange(now: true)
    }

    /// Stops and forgets the search.
    public func cancel() {
        cancelFind()
        query = ""
        results = []
        pagesSearched = 0
        isSearching = false
        scheduleChange(now: true)
    }

    private func cancelFind() {
        // Cleared first: cancelling can report the end of the old find
        // synchronously, and that must not count as this search finishing.
        isSearching = false
        if document.isFinding { document.cancelFindString() }
    }

    // MARK: Notifications

    private func didFind(_ selection: PDFSelection?) {
        guard isSearching, let selection, let page = selection.pages.first else { return }
        let pageIndex = document.index(for: page)
        let range = selection.range(at: 0, on: page)
        if options.wholeWord {
            guard range.location != NSNotFound, SearchText.isWholeWord(range, in: text(ofPageAt: pageIndex)) else { return }
        }
        selection.color = .findHighlightColor
        results.append(SearchResult(selection: selection, pageIndex: pageIndex, range: range, search: self))
        scheduleChange()
    }

    private func didEndPage() {
        guard isSearching else { return }
        pagesSearched = min(document.pageCount, pagesSearched + 1)
        scheduleChange()
    }

    private func didEnd() {
        // A cancelled search reports its end too; only the running one counts.
        guard isSearching, !document.isFinding else { return }
        isSearching = false
        pagesSearched = document.pageCount
        scheduleChange(now: true)
    }

    // MARK: Text

    /// A page's text, cached for the search's lifetime.
    func text(ofPageAt index: Int) -> NSString {
        if let text = pageTexts[index] { return text }
        let text = (document.page(at: index)?.string ?? "") as NSString
        pageTexts[index] = text
        return text
    }

    // MARK: Coalescing

    private func scheduleChange(now: Bool = false) {
        if now {
            changeTimer?.invalidate()
            changeTimer = nil
            onChange?()
            return
        }
        guard changeTimer == nil else { return }
        let timer = Timer(timeInterval: coalescingInterval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.changeTimer != nil else { return }
                self.changeTimer = nil
                self.onChange?()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        changeTimer = timer
    }
}

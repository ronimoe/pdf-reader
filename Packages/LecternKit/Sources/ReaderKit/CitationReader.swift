import PDFKit
import ReaderCore

/// Reads what a document's reference list says about the work a citation link points to
/// (citation previews). Everything comes from the document's own text; nothing goes over the
/// network.
///
/// A link is a citation when its words aren't a cross-reference ("Figure 3"), its destination
/// comes after a reference-list heading with no outline section in between (an appendix after
/// the references, say), and the entry there reads as a reference.
public final class CitationReader {
    private weak var document: PDFDocument?
    /// The reference-list headings found on each page looked at.
    private var headings: [Int: [CGRect]] = [:]
    private var outline: [(page: Int, y: CGFloat)]?
    private var pageLines: [Int: [TextLine]] = [:]

    /// How many pages before the destination to look for the heading.
    static let headingSearchPages = 40

    public init() {}

    /// The work cited by a link with the words `linkText` going to `destination`, or nil if it
    /// isn't a citation, or its entry can't be read.
    public func work(citedBy linkText: String, at destination: PDFDestination) -> CitedWork? {
        guard ReferenceList.couldBeCitation(linkText: linkText), LinkClassifier.hasPosition(destination),
              let page = destination.page, let document = page.document else { return nil }
        let pageIndex = document.index(for: page)
        guard pageIndex != NSNotFound else { return nil }
        if document !== self.document {
            self.document = document
            headings = [:]
            outline = nil
            pageLines = [:]
        }
        let onPage = lines(ofPageAt: pageIndex, in: document)
        var point = destination.point
        if point.x == kPDFDestinationUnspecifiedValue || !point.x.isFinite {
            // No left given: the page's text margin.
            point.x = onPage.map(\.bounds.minX).min() ?? page.bounds(for: .cropBox).minX
        }
        // The entry first: most cross-references (equations, theorems) stop here, before the
        // pages are searched for the heading.
        guard let first = ReferenceList.firstRow(below: point, in: onPage) else { return nil }
        let nextPage = pageIndex + 1 < document.pageCount ? lines(ofPageAt: pageIndex + 1, in: document) : []
        guard let text = ReferenceList.entry(at: point, in: onPage, nextPage: nextPage) else { return nil }
        let work = CitedWork(parsing: text)
        guard work.looksLikeReference,
              let heading = heading(before: first.bounds, onPageAt: pageIndex, in: document),
              !hasSection(after: heading, before: (pageIndex, point), in: document) else { return nil }
        return work
    }

    /// The text lines of `page`, in page space.
    public static func lines(of page: PDFPage) -> [TextLine] {
        guard let selection = page.selection(for: page.bounds(for: .cropBox)) else { return [] }
        return selection.selectionsByLine().compactMap { line in
            guard let text = line.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return TextLine(text: text, bounds: line.bounds(for: page))
        }
    }

    // MARK: Where the reference list is

    /// The nearest reference-list heading before the entry whose first line is `first`: on its
    /// page, above it in its column or in a column to its left; else on an earlier page.
    private func heading(before first: CGRect, onPageAt pageIndex: Int, in document: PDFDocument) -> (page: Int, bounds: CGRect)? {
        for index in stride(from: pageIndex, through: max(0, pageIndex - Self.headingSearchPages), by: -1) {
            let found = headings(onPageAt: index, in: document).filter { bounds in
                guard index == pageIndex else { return true }
                // A heading is over its column, flush left or centred.
                let sameColumn = bounds.midX >= first.minX - 20 && bounds.midX <= first.maxX + 20
                let above = bounds.minY >= first.maxY - 2 && sameColumn
                let columnToTheLeft = bounds.maxX <= first.minX && !sameColumn
                return above || columnToTheLeft
            }
            if let last = found.min(by: { $0.minY < $1.minY }) { return (index, last) }
        }
        return nil
    }

    private func headings(onPageAt index: Int, in document: PDFDocument) -> [CGRect] {
        if let known = headings[index] { return known }
        var found: [CGRect] = []
        if let page = document.page(at: index), ReferenceList.mightHaveHeading(page.string ?? "") {
            found = lines(ofPageAt: index, in: document).filter { ReferenceList.isHeading($0.text) }.map(\.bounds)
        }
        headings[index] = found
        return found
    }

    /// Whether the outline has a section starting after the heading and before the
    /// destination.
    private func hasSection(after heading: (page: Int, bounds: CGRect), before destination: (page: Int, point: CGPoint), in document: PDFDocument) -> Bool {
        outlinePositions(in: document).contains { item in
            let afterHeading = item.page > heading.page || (item.page == heading.page && item.y < heading.bounds.minY - 2)
            let beforeDestination = item.page < destination.page || (item.page == destination.page && item.y > destination.point.y + 2)
            return afterHeading && beforeDestination
        }
    }

    /// Where each outline item other than the reference list's own starts.
    private func outlinePositions(in document: PDFDocument) -> [(page: Int, y: CGFloat)] {
        if let outline { return outline }
        var positions: [(page: Int, y: CGFloat)] = []
        func walk(_ item: PDFOutline) {
            for index in 0..<item.numberOfChildren {
                guard let child = item.child(at: index) else { continue }
                if !ReferenceList.isHeading(child.label ?? ""),
                   let destination = child.destination ?? (child.action as? PDFActionGoTo)?.destination,
                   let page = destination.page {
                    let pageIndex = document.index(for: page)
                    if pageIndex != NSNotFound {
                        let y = LinkClassifier.hasPosition(destination) ? destination.point.y : page.bounds(for: .cropBox).maxY
                        positions.append((pageIndex, y))
                    }
                }
                walk(child)
            }
        }
        if let root = document.outlineRoot { walk(root) }
        outline = positions
        return positions
    }

    private func lines(ofPageAt index: Int, in document: PDFDocument) -> [TextLine] {
        if let known = pageLines[index] { return known }
        guard let page = document.page(at: index) else { return [] }
        let lines = Self.lines(of: page)
        // A few pages: the heading's and the destination's are usually all that's asked for.
        if pageLines.count >= 4 { pageLines = [:] }
        pageLines[index] = lines
        return lines
    }
}

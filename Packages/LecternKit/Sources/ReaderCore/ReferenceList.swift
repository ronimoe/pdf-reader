import CoreGraphics
import Foundation

/// A line of text on a page, as PDFKit groups it, in page space (y up).
public struct TextLine: Equatable, Sendable {
    public var text: String
    public var bounds: CGRect

    public init(text: String, bounds: CGRect) {
        self.text = text
        self.bounds = bounds
    }
}

/// Finding a reference list and its entries from a page's lines (citation previews).
///
/// An entry is found by where its lines are, not by the order of the page's text: PDFKit can
/// put a numbered list's labels after the entries they belong to. A citation link's
/// destination is just above the entry's first line. The entry's later lines are indented from
/// that line (a hanging indent, or the text beside a label); the next entry starts back at the
/// first line's edge, or, in a list without indents, after extra space.
public enum ReferenceList {
    /// Whether `line` is a reference list's heading: "References", "7 Bibliography",
    /// "REFERENCES", "R EFERENCES" (small capitals), and a few other languages.
    public static func isHeading(_ line: String) -> Bool {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if headings.contains(key(text)) { return true }
        guard let number = ReferenceText.firstMatch(sectionNumber, in: text) else { return false }
        return headings.contains(key((text as NSString).substring(from: NSMaxRange(number.range))))
    }

    /// Whether some line of `pageText` could be a heading: a quick test before measuring the
    /// page's lines.
    public static func mightHaveHeading(_ pageText: String) -> Bool {
        let folded = key(pageText)
        return headingStems.contains { folded.contains($0) }
    }

    /// Whether a link's words could be a citation ("12", "[3, 4]", "Smith et al., 2020"), rather
    /// than a cross-reference ("Figure 3", "Section 2.1", "B.1", "(4)").
    public static func couldBeCitation(linkText: String) -> Bool {
        let text = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        return ReferenceText.firstMatch(crossReference, in: text) == nil
    }

    /// The text of the entry whose first line is just below `point`, on one line, or nil if no
    /// line is there. `nextPage` holds the following page's lines, where an entry may end.
    public static func entry(at point: CGPoint, in lines: [TextLine], nextPage: [TextLine] = []) -> String? {
        var pageLines = lines.filter(hasText)
        var nextPage = nextPage.filter(hasText)
        guard let start = start(below: point, in: pageLines) else { return nil }
        var column = start.column
        var next = start.row + 1
        let height = max(column.rows[start.row].bounds.height, 1)
        var taken = [column.rows[start.row]]
        // Whether the entry's later lines are indented (unknown until its second line), and
        // where they start in this column.
        var indented: Bool?
        var continuation: CGFloat?
        while taken.count < maximumLines {
            guard next < column.rows.count else {
                // The entry may go on at the top of the next column, or of the next page's first,
                // indented like an entry's later lines: not at the edge, and not centred like a
                // heading. A running head or page number above the column is passed over.
                guard indented != false else { break }
                var following = Column(after: column, in: pageLines)
                if following == nil, let first = Column(firstIn: nextPage) {
                    following = first
                    pageLines = nextPage
                    nextPage = []
                }
                guard let following,
                      let top = following.rows.firstIndex(where: { $0.bounds.minX - following.left <= 40 }),
                      !isHeading(following.rows[top].text),
                      following.rows[top].bounds.minX - following.left > 1.5 else { break }
                taken.append(following.rows[top])
                column = following
                indented = true
                continuation = following.rows[top].bounds.minX
                next = top + 1
                continue
            }
            let line = column.rows[next]
            let gap = taken[taken.count - 1].bounds.minY - line.bounds.maxY
            if gap > 2 * height {
                // Only a page number or a short footer below: the column has ended, not the entry.
                let furniture = column.rows[next...].allSatisfy { $0.bounds.width < 0.3 * (column.right - column.left) }
                if furniture {
                    next = column.rows.count
                    continue
                }
                break
            }
            next += 1
            if isHeading(line.text) { break }
            if line.bounds.minX <= column.left + 1.5 {
                // Back at the entry's edge: the next entry, unless the list has no indents and
                // neither a label nor extra space says so.
                if indented == true || gap > 0.5 * height || startsWithLabel(line) { break }
                indented = false
            } else if let continuation {
                // An entry's later lines line up; anything else (a centred heading) ends it.
                if abs(line.bounds.minX - continuation) > 2 { break }
            } else if indented == nil {
                indented = true
                continuation = line.bounds.minX
            }
            taken.append(line)
        }
        let text = joined(taken.map(\.text))
        return text.isEmpty ? nil : text
    }

    /// The row an entry starts on, just below `point`: its label and text together.
    public static func firstRow(below point: CGPoint, in lines: [TextLine]) -> TextLine? {
        start(below: point, in: lines.filter(hasText)).map { $0.column.rows[$0.row] }
    }

    /// The lines joined into one: a word broken at a line's end is put back together, with its
    /// hyphen only if it goes on in capitals ("OGB-" "LSC"), and an address broken across
    /// lines is closed up.
    public static func joined(_ lines: [String]) -> String {
        var result = ""
        for line in lines {
            let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            guard let first = line.first, !result.isEmpty else {
                result += line
                continue
            }
            let lastWord = String(result.split(separator: " ").last ?? "")
            let inAddress = ReferenceText.firstMatch(addressFragment, in: lastWord) != nil
            // An address goes on when the next line does not start a sentence or a bracket; a
            // break may come after one of its own full stops ("https://doi.org/10." "14778/…").
            let continuesAddress = inAddress && (first.isLowercase || first.isNumber || "/-_~%#?=&.".contains(first))
            if result.hasSuffix("-"), first.isLetter, !inAddress {
                if first.isLowercase { result.removeLast() }
                result += line
            } else if continuesAddress {
                result += line
            } else {
                result += " " + line
            }
        }
        return result
    }

    // MARK: Lines

    static let maximumLines = 14

    /// A line starting with a numbered entry's label. Only a line at the column's edge can: a
    /// later line of an entry may start with a year ("2015.").
    static let labelStart = ReferenceText.pattern(#"^\s*(?:\[[^\]]{1,12}\]|\d{1,4}\.)\s"#)

    static func startsWithLabel(_ line: TextLine) -> Bool {
        ReferenceText.firstMatch(labelStart, in: line.text) != nil
    }

    static func hasText(_ line: TextLine) -> Bool {
        !line.text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The column an entry starts in, and the index of its first row: the row of the line just
    /// below `point`.
    static func start(below point: CGPoint, in lines: [TextLine]) -> (column: Column, row: Int)? {
        guard let first = firstLine(below: point, in: lines) else { return nil }
        let column = Column(left: first.bounds.minX, in: lines)
        let center = CGPoint(x: first.bounds.midX, y: first.bounds.midY)
        guard let row = column.rows.firstIndex(where: { $0.bounds.insetBy(dx: -0.5, dy: -0.5).contains(center) }) else { return nil }
        return (column, row)
    }

    /// A column of a page, as rows top to bottom. PDFKit splits a printed line into pieces at a
    /// label's gap or a wide justified space; a row joins up the pieces between the column's
    /// edges. The right edge is where the column's lines reach: the next column starts beyond.
    struct Column {
        let left: CGFloat
        let right: CGFloat
        let rows: [TextLine]

        /// The column whose lines start at `left`. Labels set right-aligned ("9.", "10.") start a
        /// little further left.
        init(left: CGFloat, in lines: [TextLine]) {
            let starting = lines.filter { $0.bounds.minX >= left - 12 && $0.bounds.minX <= left + 60 }
            let right = starting.map(\.bounds.maxX).max() ?? left
            let pieces = lines.filter { $0.bounds.minX >= left - 12 && $0.bounds.minX < right - 1 }
                .sorted { $0.bounds.midY > $1.bounds.midY }
            var rows: [[TextLine]] = []
            for piece in pieces {
                if let row = rows.last?.first, abs(row.bounds.midY - piece.bounds.midY) < 0.5 * min(row.bounds.height, piece.bounds.height) {
                    rows[rows.count - 1].append(piece)
                } else {
                    rows.append([piece])
                }
            }
            self.left = left
            self.right = right
            self.rows = rows.map { row in
                let row = row.sorted { $0.bounds.minX < $1.bounds.minX }
                let text = row.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
                return TextLine(text: text, bounds: row.dropFirst().reduce(row[0].bounds) { $0.union($1.bounds) })
            }
        }

        /// The column to the right of `column`.
        init?(after column: Column, in lines: [TextLine]) {
            self.init(firstIn: lines.filter { $0.bounds.minX >= column.right + 1 })
        }

        /// The leftmost column of `lines`. Its left edge is the leftmost place two lines start,
        /// so a page number or running head alone doesn't count.
        init?(firstIn lines: [TextLine]) {
            let starts = lines.map(\.bounds.minX).sorted()
            guard let left = starts.indices.dropLast().first(where: { starts[$0 + 1] - starts[$0] <= 1 }).map({ starts[$0] }) else { return nil }
            self.init(left: left, in: lines)
        }
    }

    /// The nearest line just below `point`, starting near it: a destination is placed a little
    /// above an entry and, for a hanging indent or a label, a little to its left.
    static func firstLine(below point: CGPoint, in lines: [TextLine]) -> TextLine? {
        lines.filter { line in
            let bounds = line.bounds
            return bounds.maxY <= point.y + 0.7 * bounds.height && point.y - bounds.maxY <= max(3 * bounds.height, 30)
                && bounds.minX >= point.x - 8 && bounds.minX <= point.x + 60
        }
        .max { a, b in
            a.bounds.maxY != b.bounds.maxY ? a.bounds.maxY < b.bounds.maxY : a.bounds.minX > b.bounds.minX
        }
    }

    // MARK: Words

    static let headings: Set<String> = [
        "references", "reference", "bibliography", "workscited", "literaturecited", "citedliterature",
        "referencesandnotes", "literature", "literatur", "literaturverzeichnis", "bibliographie",
        "referencesbibliographiques", "referencias", "bibliografia", "referenciasbibliograficas",
        "riferimentibibliografici", "litteratur", "literatuur", "literatura", "bibliografie",
    ]
    static let headingStems = ["referen", "bibliogra", "workscited", "literat"]
    static let sectionNumber = ReferenceText.pattern(#"^(?:\d+(?:\.\d+)*|[IVXLC]+|[A-Z])\.?\s+(?=\S)"#)
    static let crossReference = ReferenceText.pattern(
        #"(?i)^(?:figures?|figs?\.|tables?|tabs?\.|sections?|secs?\.|§|appendix|appendices|apps?\.|theorems?|thms?\.|lemmas?|propositions?|props?\.|corollary|corollaries|definitions?|defs?\.|algorithms?|algs?\.|equations?|eqs?\.|eqns?\.|chapters?|chaps?\.|ch\.|examples?|remarks?|assumptions?|lines?|footnotes?|listings?|parts?|pages?|pp?\.)(?:[\s~\d]|$)|^[A-Z](?:\.\d+)*\.?$|^\d+(?:\.\d+)+$|^\(\d+(?:\.\d+)?[a-z]?\)$"#
    )
    /// The end of a URL or DOI that may go on on the next line.
    static let addressFragment = ReferenceText.pattern(#"(?i)(?:https?://|www\.|doi\.org|^10\.\d{4,9}/)"#)

    /// Lower case, without accents or spaces.
    static func key(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).filter { !$0.isWhitespace }
    }
}

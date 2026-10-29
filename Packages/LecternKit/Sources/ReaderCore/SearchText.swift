import Foundation

/// The search field's options (B8). Matching ignores case and accents by
/// default.
public struct SearchOptions: Codable, Hashable, Sendable {
    public var matchCase: Bool
    public var wholeWord: Bool

    public init(matchCase: Bool = false, wholeWord: Bool = false) {
        self.matchCase = matchCase
        self.wholeWord = wholeWord
    }

    /// The `NSString.CompareOptions` PDFKit's find takes. Accents are always
    /// ignored; case only without Match Case. PDFKit has no whole-word option,
    /// so that is a filter (`SearchText.isWholeWord`).
    public var compareOptions: NSString.CompareOptions {
        matchCase ? [.diacriticInsensitive] : [.caseInsensitive, .diacriticInsensitive]
    }
}

/// Text handling for search results, independent of PDFKit.
public enum SearchText {
    /// Whether the match at `range` in `text` is a whole word: the characters
    /// either side, if any, are not letters, digits or combining marks.
    public static func isWholeWord(_ range: NSRange, in text: NSString) -> Bool {
        guard range.location != NSNotFound, range.length > 0, NSMaxRange(range) <= text.length else { return false }
        if range.location > 0 {
            let before = text.rangeOfComposedCharacterSequence(at: range.location - 1)
            if isWordCharacter(text.substring(with: before)) { return false }
        }
        if NSMaxRange(range) < text.length {
            let after = text.rangeOfComposedCharacterSequence(at: NSMaxRange(range))
            if isWordCharacter(text.substring(with: after)) { return false }
        }
        return true
    }

    private static let wordCharacters = CharacterSet.alphanumerics.union(.nonBaseCharacters)

    private static func isWordCharacter(_ character: String) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        return wordCharacters.contains(scalar)
    }

    /// A one-line excerpt around a match for the results list: up to
    /// `radius` characters either side, cut at word boundaries where
    /// possible, with whitespace runs collapsed. Returns the excerpt and the
    /// match's range inside it.
    public static func excerpt(around range: NSRange, in text: NSString, radius: Int = 40) -> (text: String, match: NSRange) {
        guard range.location != NSNotFound, NSMaxRange(range) <= text.length else { return ("", NSRange(location: 0, length: 0)) }
        var start = max(0, range.location - radius)
        var end = min(text.length, NSMaxRange(range) + radius)
        // Don't cut a word in half at either end.
        if start > 0 {
            let space = text.rangeOfCharacter(from: .whitespacesAndNewlines, options: [], range: NSRange(location: start, length: range.location - start))
            if space.location != NSNotFound { start = NSMaxRange(space) }
        }
        if end < text.length {
            let space = text.rangeOfCharacter(from: .whitespacesAndNewlines, options: .backwards, range: NSRange(location: NSMaxRange(range), length: end - NSMaxRange(range)))
            if space.location != NSNotFound { end = space.location }
        }
        start = text.rangeOfComposedCharacterSequence(at: start).location
        let before = collapse(text.substring(with: NSRange(location: start, length: range.location - start)))
        let match = collapse(text.substring(with: range))
        let after = collapse(text.substring(with: NSRange(location: NSMaxRange(range), length: end - NSMaxRange(range))))
        let prefix = (start > 0 ? "…" : "") + before
        let suffix = after + (end < text.length ? "…" : "")
        let matchRange = NSRange(location: (prefix as NSString).length, length: (match as NSString).length)
        return (prefix + match + suffix, matchRange)
    }

    private static func collapse(_ string: String) -> String {
        string.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}

/// What the search status line says (B8).
public struct SearchSummary: Hashable, Sendable {
    public var resultCount: Int
    public var isSearching: Bool
    /// Pages with no text layer, once known.
    public var pagesWithoutText: Int?
    public var pageCount: Int

    public init(resultCount: Int, isSearching: Bool, pagesWithoutText: Int?, pageCount: Int) {
        self.resultCount = resultCount
        self.isSearching = isSearching
        self.pagesWithoutText = pagesWithoutText
        self.pageCount = pageCount
    }

    /// True when no page has any text: searching can never find anything.
    public var documentHasNoText: Bool {
        pageCount > 0 && pagesWithoutText == pageCount
    }

    public var status: String {
        if documentHasNoText { return "This document has no searchable text" }
        let count = resultCount == 1 ? "1 result" : "\(resultCount) results"
        if isSearching { return resultCount == 0 ? "Searching…" : "Searching… \(count)" }
        return resultCount == 0 ? "No results" : count
    }

    /// A second line for a partly scanned document.
    public var textCoverageNote: String? {
        guard let missing = pagesWithoutText, missing > 0, !documentHasNoText else { return nil }
        let pages = missing == 1 ? "1 page has" : "\(missing) pages have"
        return "\(pages) no searchable text and can’t be searched."
    }
}

import Foundation

/// What a reference list says about a cited work (citation previews), read from the entry's
/// printed text, offline. A reference list never carries a work's abstract or keywords, so
/// those aren't here.
public struct CitedWork: Equatable, Sendable {
    /// The authors as printed, "et al." included.
    public var authors: String?
    public var title: String?
    /// Where it appeared: the journal, proceedings, book series or publisher.
    public var series: String?
    public var year: Int?
    /// The entry's own URL, else the address of its DOI or arXiv identifier.
    public var url: URL?
    /// The entry on one line, without its label.
    public var reference: String

    public init(authors: String? = nil, title: String? = nil, series: String? = nil, year: Int? = nil, url: URL? = nil, reference: String) {
        self.authors = authors
        self.title = title
        self.series = series
        self.year = year
        self.url = url
        self.reference = reference
    }

    /// Whether the text read as a reference at all: a title, and a year or an address. Prose
    /// from a section after the reference list almost never has both.
    public var looksLikeReference: Bool { title != nil && (year != nil || url != nil) }
}

extension CitedWork {
    /// Reads an entry in any of the common styles: numbered or author-year; names given first
    /// ("A. Smith", "Ann Smith") or surname first ("Smith, A.", "Smith A"); the title in quotes
    /// (IEEE, Chicago) or as the sentence after the names (ACM, APA, natbib, Springer, Nature,
    /// Vancouver). A part it can't find is nil.
    public init(parsing entry: String) {
        let text = ReferenceText.removingLabel(ReferenceText.normalized(entry))
        self.init(reference: text)
        var rest = text
        url = ReferenceText.takeAddresses(from: &rest)
        rest = ReferenceText.tidied(rest)

        var remainder: String
        // A series or publisher found inside the title's sentence.
        var knownSeries: String?
        if let quoted = ReferenceText.quotedTitle(in: rest) {
            title = ReferenceText.cleanedTitle(quoted.title)
            var before = quoted.before
            if let found = ReferenceText.takeTrailingYear(from: &before) { year = found }
            authors = ReferenceText.cleanedNames(before)
            remainder = quoted.after
        } else {
            let names = ReferenceText.splitNames(rest)
            // "OpenAI (2023)": a name list read up to the full stop can end with the year.
            var nameText = names?.names ?? ""
            if let found = ReferenceText.takeTrailingYear(from: &nameText) { year = found }
            authors = ReferenceText.cleanedNames(nameText)
            var afterNames = names?.rest ?? rest
            if let found = ReferenceText.takeLeadingYear(from: &afterNames) { year = found }
            let sentence = ReferenceText.firstSentence(of: afterNames) ?? (afterNames, "")
            var titleText = sentence.sentence
            remainder = sentence.rest
            // A book's edition ends its title: "Heat Transfer (5th ed.) CRC Press".
            if let edition = ReferenceText.firstMatch(ReferenceText.edition, in: titleText) {
                let ns = titleText as NSString
                remainder = ns.substring(from: NSMaxRange(edition.range)) + " " + remainder
                titleText = ns.substring(to: edition.range.location)
            }
            // And the series it is a volume of, or a chapter's pages: "Concentration of Measure,
            // volume 10 of Foundations and Trends", "Generalization Performance, pp. 43–54".
            if let series = ReferenceText.firstMatch(ReferenceText.volumeOfSeries, in: titleText) {
                let ns = titleText as NSString
                knownSeries = ns.substring(with: series.range(at: 1))
                titleText = ns.substring(to: series.range.location)
            } else if let pages = ReferenceText.firstMatch(ReferenceText.trailingPages, in: titleText) {
                titleText = (titleText as NSString).substring(to: pages.range.location)
            }
            // So does its publisher and year in brackets: "Deep Learning (MIT Press, 2016)".
            if let publisher = ReferenceText.firstMatch(ReferenceText.bracketedPublisher, in: titleText) {
                let ns = titleText as NSString
                knownSeries = ns.substring(with: publisher.range(at: 1))
                year = year ?? Int(ns.substring(with: publisher.range(at: 2)))
                titleText = ns.substring(to: publisher.range.location)
            }
            if let found = ReferenceText.takeTrailingYear(from: &titleText), year == nil { year = found }
            title = ReferenceText.cleanedTitle(titleText)
        }
        remainder = ReferenceText.tidied(remainder)
        if year == nil { year = ReferenceText.year(in: remainder) }
        series = knownSeries ?? ReferenceText.series(in: remainder)
    }
}

/// The text handling behind `CitedWork(parsing:)`.
enum ReferenceText {
    // MARK: Cleaning

    static func normalized(_ text: String) -> String {
        var text = text
        for (from, to) in [("\u{00A0}", " "), ("\u{2010}", "-"), ("\u{2011}", "-"), ("ﬁ", "fi"), ("ﬂ", "fl"), ("ﬀ", "ff"), ("ﬃ", "ffi"), ("ﬄ", "ffl"), ("``", "“"), ("''", "”")] {
            text = text.replacingOccurrences(of: from, with: to)
        }
        // TeX fonts set an accent as a glyph of its own before the letter: "L´opez", "J¨urgen".
        for (accent, mark) in spacingAccents {
            text = replacing(accent, in: text, with: "$1" + mark)
        }
        text = text.precomposedStringWithCanonicalMapping
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static let spacingAccents = [("´", "\u{301}"), ("¨", "\u{308}"), ("ˆ", "\u{302}"), ("˜", "\u{303}"), ("ˇ", "\u{30C}"), ("˚", "\u{30A}")]
        .map { (pattern("\($0.0) ?(\\p{L})"), $0.1) }
        // A grave accent is the backtick, which also opens quotes: only before a small vowel.
        + [(pattern("`([aeiou])"), "\u{300}")]

    /// "[12]", "[Smi20]", "(3)", "12." or a bare "12" before a name.
    static let label = pattern(#"^(?:\[[^\]]{1,24}\]|\(\d{1,4}\)|\d{1,4}\.(?=\s)|\d{1,4}(?=\s+\p{Lu}))\s*"#)

    static func removingLabel(_ text: String) -> String {
        guard let match = firstMatch(label, in: text) else { return text }
        return (text as NSString).substring(from: NSMaxRange(match.range))
    }

    /// Closes up the space and doubled punctuation that removing a part leaves: "Press, ." and
    /// "2010. ." become "Press." and "2010.". An initial's full stop before a comma ("Smith, A.,
    /// Jones, B.") stays.
    static func tidied(_ text: String) -> String {
        var text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        text = replacing(spaceBeforePunctuation, in: text, with: "$1")
        text = replacing(punctuationBeforeStop, in: text, with: ".")
        text = replacing(repeatedComma, in: text, with: ",")
        return text.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:"))
    }

    static let spaceBeforePunctuation = pattern(#"\s+([.,;:])"#)
    static let punctuationBeforeStop = pattern(#"[.,;:](?:\s*[.,;:])*\s*\.(?!\w)"#)
    static let repeatedComma = pattern(#",(?:\s*,)+"#)

    // MARK: Addresses

    /// A URL; the text layer sometimes has a space after its scheme ("http: //").
    static let webAddress = pattern(#"(?i)\b(?:https?: ?//|www\.)[^\s<>"“”]+"#)
    /// A DOI, allowing the single spaces some PDFs put around its "." and "/".
    static let doi = pattern(#"\b10 ?\. ?\d{4,9} ?/ ?[^\s/]+(?: ?/ ?[^\s/]+)*"#)
    static let arxiv = pattern(#"(?i)\barxiv(?:\s+preprint)?(?:\s+arxiv)?\s*:?\s*(\d{4}\.\d{4,5}|[a-z][a-z.-]*/\d{7})(?:v\d+)?"#)
    static let yearAfterAddress = pattern(#"[,(](?:1[6-9]\d{2}|20\d{2})[a-z]?\)?[.,;]?$"#)
    /// The words that introduce an address: "URL", "[Online]. Available:", "doi:".
    static let addressMarker = pattern(#"(?i)(?:\[online\]\.?\s*)?(?:\b(?:available(?:\s+(?:at|online|from))?|url|retrieved\s+from|doi)\s*:?\s*)$"#)

    /// The entry's address: a printed URL, else its DOI's, else its arXiv identifier's. Printed
    /// URLs and DOIs are removed from `text` with the words introducing them; an arXiv
    /// identifier stays, as it also says where the work appeared.
    static func takeAddresses(from text: inout String) -> URL? {
        var found: [(range: NSRange, url: URL?)] = []
        for match in matches(webAddress, in: text) {
            let raw = trimmedAddress((text as NSString).substring(with: match.range))
            let address = raw.replacingOccurrences(of: " ", with: "")
            let url = URL(string: address.lowercased().hasPrefix("www.") ? "https://" + address : address)
            found.append((NSRange(location: match.range.location, length: raw.utf16.count), url?.host == nil ? nil : url))
        }
        var doiURL: URL?
        for match in matches(doi, in: text) where !found.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 }) {
            let raw = trimmedAddress((text as NSString).substring(with: match.range))
            let doi = raw.replacingOccurrences(of: " ", with: "")
            let encoded = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? doi
            if doiURL == nil { doiURL = URL(string: "https://doi.org/" + encoded) }
            found.append((NSRange(location: match.range.location, length: raw.utf16.count), nil))
        }
        var arxivURL: URL?
        if let match = firstMatch(arxiv, in: text) {
            arxivURL = URL(string: "https://arxiv.org/abs/" + (text as NSString).substring(with: match.range(at: 1)))
        }
        let url = found.lazy.compactMap(\.url).first ?? doiURL ?? arxivURL
        // Removed from the end, so the earlier ranges stay valid.
        for item in found.sorted(by: { $0.range.location > $1.range.location }) {
            let ns = text as NSString
            var start = item.range.location
            if let marker = firstMatch(addressMarker, in: ns.substring(to: start)) { start = marker.range.location }
            text = ns.replacingCharacters(in: NSRange(location: start, length: NSMaxRange(item.range) - start), with: " ")
        }
        return url
    }

    /// Without the sentence's own punctuation after it, a bracket it doesn't open, or a year
    /// the text layer ran into it ("…/gpt-4,2023").
    static func trimmedAddress(_ raw: String) -> String {
        var raw = raw
        if let year = firstMatch(yearAfterAddress, in: raw) { raw = (raw as NSString).substring(to: year.range.location) }
        while let last = raw.last {
            if ".,;:".contains(last) {
                raw.removeLast()
            } else if last == ")", raw.filter({ $0 == "(" }).count < raw.filter({ $0 == ")" }).count {
                raw.removeLast()
            } else if last == "]", raw.filter({ $0 == "[" }).count < raw.filter({ $0 == "]" }).count {
                raw.removeLast()
            } else {
                break
            }
        }
        return raw
    }

    // MARK: Names

    /// A surname: capitalised, up to three words, maybe after "van", "de"…
    static let surname = #"(?:(?:van|von|der|den|de|del|della|di|da|du|le|la|ter|ten|dos|das|el|al|bin|ibn)\s)*\p{Lu}[\p{L}\p{M}'’-]+(?:[\s-]\p{Lu}[\p{L}\p{M}'’-]+){0,2}"#
    static let initials = #"\p{Lu}\.(?:\s?-?\s?\p{Lu}\.)*"#
    static let suffix = #"(?:,?\s(?:Jr\.|Sr\.|II|III|IV))?"#
    static let etAl = #"(?:,?\s(?:et\sal\.?|and\sothers))?"#
    /// "Smith, J. R., Jones, B. & Lee, C." (APA, Springer, Nature, Harvard), and "Smith, J. R.,
    /// B. Jones, and C. Lee" (Chicago: only the first name turned round).
    static let surnameFirst = pattern(
        "^\(surname),\\s?\(initials)\(suffix)(?:(?:\\s?,\\s?(?:and\\s|&\\s?)?|\\s?;\\s?|\\sand\\s|\\s?&\\s?)(?:\(surname),\\s?\(initials)\(suffix)|\(initials)\\s?\(surname)))*\(etAl)"
    )
    /// "Smith JR, Jones B, Lee C." (Vancouver): at least two names, or one and "et al".
    static let surnameInitialsUnpunctuated = pattern(
        "^(?:\(surname)\\s\\p{Lu}{1,3}(?:,\\s?\(surname)\\s\\p{Lu}{1,3})+(?:,?\\set\\sal)?|\(surname)\\s\\p{Lu}{1,3},?\\set\\sal)\\.(?=\\s|$)"
    )
    static let singleSurnameInitials = pattern("^\(surname)\\s\\p{Lu}{1,3}\\.(?=\\s)")
    static let vancouverDate = pattern(#";\s?(?:1[6-9]|20)\d{2}\b|\b(?:1[6-9]|20)\d{2};"#)
    /// "J. R. Smith, B. Jones, and C. Lee" (IEEE, ACM, natbib with initials).
    static let initialsFirst = pattern(
        "^\(initials)\\s?\(surname)(?:(?:,\\s(?:and\\s)?|\\sand\\s|,?\\s?&\\s?)\(initials)\\s?\(surname))*\(etAl)"
    )

    /// The author list at the start of `text`, and the text after it. Names written with
    /// initials are matched as names; full names end at the first full stop.
    static func splitNames(_ text: String) -> (names: String, rest: String)? {
        let ns = text as NSString
        for pattern in [surnameFirst, surnameInitialsUnpunctuated, initialsFirst] {
            guard let match = firstMatch(pattern, in: text), match.range.length > 0 else { continue }
            var names = ns.substring(with: match.range)
            let after = ns.substring(from: NSMaxRange(match.range))
            // The list must end where the names do: at punctuation, a year or the title, and
            // not before another name ("and J. Ba").
            let ended = after.first.map { ",.:;(".contains($0) || (names.hasSuffix(".") && $0 == " ") } ?? true
            let next = after.drop { " ,".contains($0) }
            guard ended, !next.hasPrefix("and "), !next.hasPrefix("&") else { continue }
            // Vancouver initials have no full stops: the last one ends the list, not an initial.
            if pattern === surnameInitialsUnpunctuated { names.removeLast() }
            return (names, after.trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;")))
        }
        // "Lovelace A. Notes…": a single Vancouver name, told from "Ada A. Lovelace" by the
        // style's dates ("; 1843.", ". 2022;78").
        if firstMatch(vancouverDate, in: text) != nil, let match = firstMatch(singleSurnameInitials, in: text) {
            return (String(ns.substring(with: match.range).dropLast()), ns.substring(from: NSMaxRange(match.range)).trimmingCharacters(in: .whitespaces))
        }
        guard let sentence = firstSentence(of: text) else { return nil }
        // "OpenAI: GPT-4 technical report." (Springer): a name, then a colon, then the title.
        if let colon = firstMatch(namesThenColon, in: sentence.sentence) {
            let ns = sentence.sentence as NSString
            return (ns.substring(with: colon.range(at: 1)), ns.substring(from: NSMaxRange(colon.range)) + ". " + sentence.rest)
        }
        return (sentence.sentence, sentence.rest)
    }

    /// Up to four capitalised words (with "and", "&" or particles between) and a colon.
    static let namesThenColon = pattern(#"^((?:\p{Lu}[\p{L}\p{M}'’.-]*|and|&|van|von|de|der|la|et\sal\.?)(?:[\s,]+(?:\p{Lu}[\p{L}\p{M}'’.-]*|and|&|van|von|de|der|la|et\sal\.?)){0,3}):\s"#)

    /// The names without the punctuation around them, keeping the full stop of a final
    /// initial or "et al.".
    static func cleanedNames(_ names: String) -> String? {
        var names = names.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:"))
        if names.hasSuffix(".") {
            let word = String(names.dropLast().reversed().prefix { $0.isLetter }.reversed())
            if word.count > 1, word != "al" { names.removeLast() }
        }
        names = names.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:"))
        return names.isEmpty ? nil : names
    }

    // MARK: Title

    /// A title in quotes, opened at the start or after punctuation (inside a sentence, quotes
    /// are part of an unquoted title) and closed after its own comma or full stop (IEEE,
    /// Chicago), so quotes inside it are kept: "““Why should I trust you?”: Explaining…,”".
    static let quoted = pattern(#"(?:^|[,.:;])\s*[“"](.{2,}?[,.?!])[”"](?=\s|$)"#)
    /// A title in quotes followed by its punctuation: "“Title”, Journal".
    static let quotedThenPunctuated = pattern(#"(?:^|[,.:;])\s*[“"]([^”"]{2,})[”"](?=[\s,;]|$)"#)

    static func quotedTitle(in text: String) -> (before: String, title: String, after: String)? {
        guard let match = firstMatch(quoted, in: text) ?? firstMatch(quotedThenPunctuated, in: text) else { return nil }
        let ns = text as NSString
        return (ns.substring(to: match.range.location), ns.substring(with: match.range(at: 1)), ns.substring(from: NSMaxRange(match.range)))
    }

    static let edition = pattern(#"\s\(\d+(?:st|nd|rd|th)\s(?:ed\.|edition)\)"#)
    static let volumeOfSeries = pattern(#",\s(?:volume|vol\.)\s?\d+\sof\s(.+)$"#)
    static let trailingPages = pattern(#",\s(?:pp?\.|pages)\s?\d[\d–-]*$"#)
    static let bracketedPublisher = pattern(#"\s\(([^()]*\p{L}[^()]*?),?\s((?:1[6-9]\d{2}|20\d{2}))[a-z]?\)$"#)

    static func cleanedTitle(_ title: String) -> String? {
        let title = title.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:"))
        return title.count > 1 ? title : nil
    }

    /// Words whose full stop doesn't end a sentence. Journal abbreviations aren't here: they
    /// come after the title, where sentences aren't needed.
    static let abbreviations: Set<String> = [
        "ed", "eds", "vol", "vols", "no", "nos", "pp", "proc", "conf", "jr", "sr", "dr", "prof", "st", "vs",
        "fig", "figs", "eq", "eqs", "sec", "dept", "univ", "inc", "ltd", "corp", "approx", "etc",
    ]

    /// The first sentence of `text` and the text after it. A "?" or "!" stays in the sentence;
    /// a full stop after an initial, a single letter ("e.g.") or an abbreviation doesn't end it.
    static func firstSentence(of text: String) -> (sentence: String, rest: String)? {
        let characters = Array(text)
        for index in characters.indices where ".?!".contains(characters[index]) {
            let next = index + 1
            guard next == characters.count || characters[next] == " " else { continue }
            if characters[index] == "." {
                var start = index
                while start > 0, characters[start - 1].isLetter { start -= 1 }
                let word = String(characters[start..<index])
                if word.count == 1 || ["Ch", "Th", "Ph"].contains(word) || abbreviations.contains(word.lowercased()) { continue }
            }
            let end = characters[index] == "." ? index : next
            let rest = next < characters.count ? String(characters[(next + 1)...]) : ""
            return (String(characters[..<end]), rest)
        }
        return nil
    }

    // MARK: Year

    static let yearNumber = #"(?:1[6-9]\d{2}|20\d{2})"#
    /// "(2020)." or "(2020a, May 3)." (APA), "2020." (ACM, Harvard).
    static let leadingYear = pattern("^\\(?(\(yearNumber))[a-z]?(?:,[^)]{0,30})?\\)?[.,:]?(?:\\s|$)")
    static let trailingYear = pattern("(?:^|[\\s,.(])(\(yearNumber))[a-z]?\\)?[.,]?\\s*$")
    static let bracketedYear = pattern("\\((\(yearNumber))[a-z]?\\)")
    /// A year on its own, not part of a page range or a longer number.
    static let looseYear = pattern("(?<![\\d–-])(\(yearNumber))[a-z]?(?![\\d–-])")

    static func takeLeadingYear(from text: inout String) -> Int? {
        guard let match = firstMatch(leadingYear, in: text) else { return nil }
        let ns = text as NSString
        let year = Int(ns.substring(with: match.range(at: 1)))
        text = ns.substring(from: NSMaxRange(match.range))
        return year
    }

    static func takeTrailingYear(from text: inout String) -> Int? {
        guard let match = firstMatch(trailingYear, in: text) else { return nil }
        let ns = text as NSString
        let year = Int(ns.substring(with: match.range(at: 1)))
        text = ns.substring(to: match.range.location)
        return year
    }

    /// A year in brackets, else the last one standing on its own.
    static func year(in text: String) -> Int? {
        let ns = text as NSString
        if let match = firstMatch(bracketedYear, in: text) { return Int(ns.substring(with: match.range(at: 1))) }
        guard let match = matches(looseYear, in: text).last else { return nil }
        return Int(ns.substring(with: match.range(at: 1)))
    }

    // MARK: Series

    /// Where the place of publication ends and its details start: volume, issue, pages, year.
    static let seriesEnd = pattern(
        #"(?i),?\s*\b(?:pp\.|pages?|vol\.|volume|no\.|num\.|number|issue|art\.|article)\s*\d|,\s*\d|\s\d+\s?(?:\(\d+\))?\s?[:,]\s?\d|\.\s+\d|\s*\(\s*\d{4}|;\s*\d"#
    )
    static let leadingIn = pattern(#"^[Ii]n:?\s+"#)
    static let arxivPreprint = pattern(#"(?i)\barxiv\s+preprint\s+arxiv\s*:?\s*[\w./-]+"#)
    static let arxivIdentifier = pattern(#"(?i)\barxiv\s*:\s*[\w./-]+(?:\s*\[[^\]]*\])?"#)

    static func series(in text: String) -> String? {
        var text = text.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:"))
        text = replacing(leadingIn, in: text, with: "")
        text = replacing(arxivPreprint, in: text, with: "arXiv preprint")
        text = replacing(arxivIdentifier, in: text, with: "arXiv")
        if let end = firstMatch(seriesEnd, in: text) { text = (text as NSString).substring(to: end.range.location) }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:"))
        guard text.contains(where: \.isLetter) else { return nil }
        return text
    }

    // MARK: Regular expressions

    static func pattern(_ pattern: String) -> NSRegularExpression {
        // The patterns are fixed: a bad one is a programming error.
        try! NSRegularExpression(pattern: pattern)
    }

    static func firstMatch(_ regex: NSRegularExpression, in text: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count))
    }

    static func matches(_ regex: NSRegularExpression, in text: String) -> [NSTextCheckingResult] {
        regex.matches(in: text, range: NSRange(location: 0, length: text.utf16.count))
    }

    static func replacing(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: text.utf16.count), withTemplate: template)
    }
}

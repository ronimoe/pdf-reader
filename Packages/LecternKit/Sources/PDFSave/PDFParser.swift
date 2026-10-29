import Foundation

enum PDFLexer {
    static func isWhitespace(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09 || b == 0x0C || b == 0x00
    }

    static func isDelimiter(_ b: UInt8) -> Bool {
        switch b {
        case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "<"), UInt8(ascii: ">"),
             UInt8(ascii: "["), UInt8(ascii: "]"), UInt8(ascii: "{"), UInt8(ascii: "}"),
             UInt8(ascii: "/"), UInt8(ascii: "%"):
            true
        default: false
        }
    }

    static func hexValue(_ b: UInt8) -> UInt8? {
        switch b {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): b - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): b - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): b - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}

/// A recursive-descent parser over the raw file bytes. It never repairs: anything it does not
/// understand is a `PDFSaveError.malformed`, so the caller can route the file to Save a Copy.
struct PDFParser {
    let bytes: [UInt8]
    var pos: Int
    /// Resolves an indirect `/Length`. Returns nil if it can't.
    var lengthResolver: ((ObjectRef) -> Int?)?

    init(bytes: [UInt8], pos: Int = 0, lengthResolver: ((ObjectRef) -> Int?)? = nil) {
        self.bytes = bytes
        self.pos = pos
        self.lengthResolver = lengthResolver
    }

    var atEnd: Bool { pos >= bytes.count }

    func fail(_ what: String) -> PDFSaveError { .malformed("\(what) at offset \(pos)") }

    mutating func skipWhitespace() {
        while pos < bytes.count {
            let b = bytes[pos]
            if PDFLexer.isWhitespace(b) {
                pos += 1
            } else if b == UInt8(ascii: "%") {
                while pos < bytes.count, bytes[pos] != 0x0A, bytes[pos] != 0x0D { pos += 1 }
            } else {
                return
            }
        }
    }

    /// Reads a run of regular characters (a keyword or number token) without consuming whitespace.
    mutating func readToken() -> [UInt8] {
        let start = pos
        while pos < bytes.count, PDFSerializer.isRegular(bytes[pos]) { pos += 1 }
        return Array(bytes[start..<pos])
    }

    func peekKeyword(_ keyword: String) -> Bool {
        let k = Array(keyword.utf8)
        guard pos + k.count <= bytes.count, Array(bytes[pos..<pos + k.count]) == k else { return false }
        let end = pos + k.count
        return end == bytes.count || !PDFSerializer.isRegular(bytes[end])
    }

    mutating func expectKeyword(_ keyword: String) throws(PDFSaveError) {
        skipWhitespace()
        guard peekKeyword(keyword) else { throw fail("expected '\(keyword)'") }
        pos += keyword.utf8.count
    }

    mutating func readInteger() throws(PDFSaveError) -> Int {
        skipWhitespace()
        let token = readToken()
        guard !token.isEmpty, let value = Int(String(decoding: token, as: UTF8.self)) else {
            throw fail("expected integer")
        }
        return value
    }

    // MARK: Objects

    mutating func parseObject(depth: Int = 0) throws(PDFSaveError) -> PDFObject {
        guard depth < 200 else { throw fail("nesting too deep") }
        skipWhitespace()
        guard pos < bytes.count else { throw fail("unexpected end of file") }
        let b = bytes[pos]
        switch b {
        case UInt8(ascii: "/"):
            return .name(parseName())
        case UInt8(ascii: "("):
            return .string(try parseLiteralString())
        case UInt8(ascii: "<"):
            if pos + 1 < bytes.count, bytes[pos + 1] == UInt8(ascii: "<") {
                return .dictionary(try parseDictionary(depth: depth))
            }
            return .string(try parseHexString())
        case UInt8(ascii: "["):
            pos += 1
            var items: [PDFObject] = []
            while true {
                skipWhitespace()
                guard pos < bytes.count else { throw fail("unterminated array") }
                if bytes[pos] == UInt8(ascii: "]") { pos += 1; break }
                items.append(try parseObject(depth: depth + 1))
            }
            return .array(items)
        case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "+"), UInt8(ascii: "-"), UInt8(ascii: "."):
            return try parseNumberOrReference()
        default:
            let start = pos
            let token = String(decoding: readToken(), as: UTF8.self)
            switch token {
            case "true": return .bool(true)
            case "false": return .bool(false)
            case "null": return .null
            default:
                pos = start
                throw fail("unexpected token '\(token)'")
            }
        }
    }

    mutating func parseName() -> PDFName {
        pos += 1  // '/'
        var out: [UInt8] = []
        while pos < bytes.count, PDFSerializer.isRegular(bytes[pos]) {
            let c = bytes[pos]
            if c == UInt8(ascii: "#"), pos + 2 < bytes.count,
               let h = PDFLexer.hexValue(bytes[pos + 1]), let l = PDFLexer.hexValue(bytes[pos + 2]) {
                out.append(h << 4 | l)
                pos += 3
            } else {
                out.append(c)
                pos += 1
            }
        }
        return PDFName(bytes: out)
    }

    mutating func parseLiteralString() throws(PDFSaveError) -> PDFString {
        pos += 1  // '('
        var out: [UInt8] = []
        var depth = 1
        while pos < bytes.count {
            let c = bytes[pos]
            pos += 1
            switch c {
            case UInt8(ascii: "("):
                depth += 1; out.append(c)
            case UInt8(ascii: ")"):
                depth -= 1
                if depth == 0 { return PDFString(bytes: out, isHex: false) }
                out.append(c)
            case UInt8(ascii: "\\"):
                guard pos < bytes.count else { throw fail("unterminated string") }
                let e = bytes[pos]
                pos += 1
                switch e {
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "0")...UInt8(ascii: "7"):
                    var value = Int(e - UInt8(ascii: "0"))
                    for _ in 0..<2 {
                        guard pos < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(bytes[pos]) else { break }
                        value = value * 8 + Int(bytes[pos] - UInt8(ascii: "0"))
                        pos += 1
                    }
                    out.append(UInt8(truncatingIfNeeded: value))
                case 0x0D:  // line continuation
                    if pos < bytes.count, bytes[pos] == 0x0A { pos += 1 }
                case 0x0A:
                    break
                default:
                    out.append(e)
                }
            case 0x0D:
                // An unescaped end-of-line in a literal string reads as a single LF.
                if pos < bytes.count, bytes[pos] == 0x0A { pos += 1 }
                out.append(0x0A)
            default:
                out.append(c)
            }
        }
        throw fail("unterminated string")
    }

    mutating func parseHexString() throws(PDFSaveError) -> PDFString {
        pos += 1  // '<'
        var out: [UInt8] = []
        var high: UInt8?
        while pos < bytes.count {
            let c = bytes[pos]
            pos += 1
            if c == UInt8(ascii: ">") {
                if let h = high { out.append(h << 4) }
                return PDFString(bytes: out, isHex: true)
            }
            if PDFLexer.isWhitespace(c) { continue }
            guard let v = PDFLexer.hexValue(c) else { throw fail("bad hex string") }
            if let h = high { out.append(h << 4 | v); high = nil } else { high = v }
        }
        throw fail("unterminated hex string")
    }

    mutating func parseDictionary(depth: Int) throws(PDFSaveError) -> PDFDictionary {
        pos += 2  // '<<'
        var dict = PDFDictionary()
        var seen = Set<PDFName>()
        while true {
            skipWhitespace()
            guard pos + 1 < bytes.count else { throw fail("unterminated dictionary") }
            if bytes[pos] == UInt8(ascii: ">"), bytes[pos + 1] == UInt8(ascii: ">") { pos += 2; break }
            guard bytes[pos] == UInt8(ascii: "/") else { throw fail("dictionary key is not a name") }
            let key = parseName()
            let value = try parseObject(depth: depth + 1)
            // Duplicate keys: the first one wins, as in most readers; keep it out of the rewrite.
            if seen.insert(key).inserted { dict[key] = value }
        }
        return dict
    }

    mutating func parseNumberOrReference() throws(PDFSaveError) -> PDFObject {
        let token = String(decoding: readToken(), as: UTF8.self)
        guard let first = parseNumber(token) else { throw fail("bad number '\(token)'") }
        guard case .integer(let number) = first, number >= 0 else { return first }
        // Look ahead for "gen R".
        let save = pos
        skipWhitespace()
        let genStart = pos
        let genToken = readToken()
        if !genToken.isEmpty, genToken.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
           let gen = Int(String(decoding: genToken, as: UTF8.self)), pos > genStart {
            skipWhitespace()
            if peekKeyword("R") {
                pos += 1
                return .reference(ObjectRef(number, gen))
            }
        }
        pos = save
        return first
    }

    func parseNumber(_ token: String) -> PDFObject? {
        if let i = Int(token) { return .integer(i) }
        // Reals: optional sign, digits with one '.', e.g. "-.5", "3.", "+1.25".
        var body = Substring(token)
        if body.first == "+" || body.first == "-" { body = body.dropFirst() }
        guard !body.isEmpty, body.filter({ $0 == "." }).count <= 1,
              body.allSatisfy({ $0 == "." || $0.isASCII && $0.isNumber }), body != "." else { return nil }
        return .real(token)
    }

    // MARK: Indirect objects

    /// Parses `num gen obj … endobj` at `pos`, including a following stream.
    mutating func parseIndirectObject() throws(PDFSaveError) -> (ObjectRef, PDFObject) {
        let number = try readInteger()
        let generation = try readInteger()
        try expectKeyword("obj")
        let ref = ObjectRef(number, generation)
        var object = try parseObject()
        skipWhitespace()
        if peekKeyword("stream") {
            guard case .dictionary(let dict) = object else { throw fail("stream without dictionary") }
            pos += "stream".utf8.count
            // The keyword is followed by CRLF or LF (a lone CR is tolerated).
            if pos < bytes.count, bytes[pos] == 0x0D { pos += 1 }
            if pos < bytes.count, bytes[pos] == 0x0A { pos += 1 }
            let dataStart = pos
            var length: Int?
            switch dict["Length"] {
            case .integer(let l)?: length = l
            case .reference(let r)?: length = lengthResolver?(r)
            default: length = nil
            }
            var dataEnd: Int?
            if let length, length >= 0, dataStart + length <= bytes.count {
                var p = PDFParser(bytes: bytes, pos: dataStart + length)
                p.skipWhitespace()
                if p.peekKeyword("endstream") {
                    dataEnd = dataStart + length
                    pos = p.pos + "endstream".utf8.count
                }
            }
            if dataEnd == nil {
                // /Length is wrong or unresolvable: fall back to the endstream keyword.
                guard let found = PDFParser.find(Array("endstream".utf8), in: bytes, from: dataStart) else {
                    throw fail("stream without endstream")
                }
                var end = found
                if end > dataStart, bytes[end - 1] == 0x0A { end -= 1 }
                if end > dataStart, bytes[end - 1] == 0x0D { end -= 1 }
                dataEnd = end
                pos = found + "endstream".utf8.count
            }
            object = .stream(PDFStream(dictionary: dict, rawData: Array(bytes[dataStart..<dataEnd!])))
        }
        try expectKeyword("endobj")
        return (ref, object)
    }

    static func find(_ needle: [UInt8], in haystack: [UInt8], from start: Int) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        var i = max(0, start)
        let last = haystack.count - needle.count
        while i <= last {
            if haystack[i] == needle[0] {
                var match = true
                for j in 1..<needle.count where haystack[i + j] != needle[j] { match = false; break }
                if match { return i }
            }
            i += 1
        }
        return nil
    }

    static func findLast(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard haystack.count >= needle.count else { return nil }
        var i = haystack.count - needle.count
        while i >= 0 {
            if haystack[i] == needle[0], Array(haystack[i..<i + needle.count]) == needle { return i }
            i -= 1
        }
        return nil
    }
}

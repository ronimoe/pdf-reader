import Foundation

/// An indirect object reference, `number generation R`.
public struct ObjectRef: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let number: Int
    public let generation: Int

    public init(_ number: Int, _ generation: Int = 0) {
        self.number = number
        self.generation = generation
    }

    public static func < (a: ObjectRef, b: ObjectRef) -> Bool {
        (a.number, a.generation) < (b.number, b.generation)
    }

    public var description: String { "\(number) \(generation) R" }
}

/// A PDF name. `bytes` holds the decoded name (after `#xx` escapes), without the leading slash.
public struct PDFName: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) { self.bytes = bytes }
    public init(_ string: String) { self.bytes = Array(string.utf8) }
    public init(stringLiteral value: String) { self.init(value) }

    public var description: String { "/" + String(decoding: bytes, as: UTF8.self) }
    public var string: String { String(decoding: bytes, as: UTF8.self) }
}

/// A PDF string. The bytes are kept exactly as decoded from the file; `isHex` only records how
/// the string was written, so it is ignored for equality.
public struct PDFString: Hashable, Sendable {
    public var bytes: [UInt8]
    public var isHex: Bool

    public init(bytes: [UInt8], isHex: Bool = false) {
        self.bytes = bytes
        self.isHex = isHex
    }

    public static func == (a: PDFString, b: PDFString) -> Bool { a.bytes == b.bytes }
    public func hash(into hasher: inout Hasher) { hasher.combine(bytes) }

    /// Encodes a text string: plain printable ASCII as a literal, anything else as UTF-16BE with a BOM.
    public init(text: String) {
        let ascii = text.unicodeScalars.allSatisfy { (0x20...0x7E).contains($0.value) || $0 == "\n" || $0 == "\t" }
        if ascii {
            self.init(bytes: Array(text.utf8), isHex: false)
        } else {
            var out: [UInt8] = [0xFE, 0xFF]
            for unit in text.utf16 { out.append(UInt8(unit >> 8)); out.append(UInt8(unit & 0xFF)) }
            self.init(bytes: out, isHex: true)
        }
    }

    /// Decodes a text string (UTF-16BE or UTF-8 with BOM, otherwise PDFDocEncoding).
    public var text: String {
        if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF {
            var units: [UInt16] = []
            var i = 2
            while i + 1 < bytes.count { units.append(UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1])); i += 2 }
            return String(decoding: units, as: UTF16.self)
        }
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            return String(decoding: bytes[3...], as: UTF8.self)
        }
        return String(String.UnicodeScalarView(bytes.map { PDFDocEncoding.scalar(for: $0) }))
    }
}

enum PDFDocEncoding {
    // PDFDocEncoding differs from Latin-1 in 0x18–0x1F and 0x80–0x9F (ISO 32000-1 Annex D).
    private static let high: [UInt32] = [
        0x2022, 0x2020, 0x2021, 0x2026, 0x2014, 0x2013, 0x0192, 0x2044, 0x2039, 0x203A, 0x2212, 0x2030,
        0x201E, 0x201C, 0x201D, 0x2018, 0x2019, 0x201A, 0x2122, 0xFB01, 0xFB02, 0x0141, 0x0152, 0x0160,
        0x0178, 0x017D, 0x0131, 0x0142, 0x0153, 0x0161, 0x017E, 0xFFFD,
    ]
    private static let low: [UInt32] = [0x02D8, 0x02C7, 0x02C6, 0x02D9, 0x02DD, 0x02DB, 0x02DA, 0x02DC]

    static func scalar(for byte: UInt8) -> Unicode.Scalar {
        switch byte {
        case 0x18...0x1F: return Unicode.Scalar(low[Int(byte) - 0x18])!
        case 0x80...0x9F: return Unicode.Scalar(high[Int(byte) - 0x80])!
        case 0xA0: return Unicode.Scalar(0x20AC)!
        default: return Unicode.Scalar(byte)
        }
    }
}

/// A dictionary that keeps its keys in file order, so a rewritten object differs from the
/// original only where we changed it.
public struct PDFDictionary: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var key: PDFName
        public var value: PDFObject
    }

    public private(set) var entries: [Entry]
    /// True when the source dictionary repeated a key. Readers disagree on such files, so the
    /// writer refuses to rewrite them.
    public internal(set) var hasDuplicateKeys = false

    public init(_ entries: [Entry] = []) { self.entries = entries }

    public subscript(key: PDFName) -> PDFObject? {
        get { entries.first { $0.key == key }?.value }
        set {
            if let index = entries.firstIndex(where: { $0.key == key }) {
                if let newValue { entries[index].value = newValue } else { entries.remove(at: index) }
            } else if let newValue {
                entries.append(Entry(key: key, value: newValue))
            }
        }
    }

    public var keys: [PDFName] { entries.map(\.key) }
}

public struct PDFStream: Equatable, Sendable {
    public var dictionary: PDFDictionary
    /// The stream data exactly as stored in the file (still encoded).
    public var rawData: [UInt8]

    public init(dictionary: PDFDictionary, rawData: [UInt8]) {
        self.dictionary = dictionary
        self.rawData = rawData
    }
}

public indirect enum PDFObject: Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int)
    /// A real number kept as the exact text from the file, so re-serialising never changes it.
    case real(String)
    case string(PDFString)
    case name(PDFName)
    case array([PDFObject])
    case dictionary(PDFDictionary)
    case stream(PDFStream)
    case reference(ObjectRef)

    public static func number(_ value: Double) -> PDFObject {
        if value == value.rounded(), abs(value) < 1e15 { return .integer(Int(value)) }
        return .real(PDFObject.format(value))
    }

    static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
        var s = String(format: "%.4f", value)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        if s == "-0" { s = "0" }
        return s
    }

    public static func text(_ string: String) -> PDFObject { .string(PDFString(text: string)) }

    public var dictionaryValue: PDFDictionary? {
        switch self {
        case .dictionary(let d): d
        case .stream(let s): s.dictionary
        default: nil
        }
    }

    public var arrayValue: [PDFObject]? { if case .array(let a) = self { a } else { nil } }
    public var referenceValue: ObjectRef? { if case .reference(let r) = self { r } else { nil } }
    public var nameValue: PDFName? { if case .name(let n) = self { n } else { nil } }
    public var stringValue: PDFString? { if case .string(let s) = self { s } else { nil } }
    public var intValue: Int? {
        switch self {
        case .integer(let i): i
        case .real(let r): Double(r).flatMap { Int(exactly: $0.rounded(.towardZero)) }
        default: nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .integer(let i): Double(i)
        case .real(let r): Double(r)
        default: nil
        }
    }
}

// MARK: - Serialisation

enum PDFSerializer {
    static func isRegular(_ b: UInt8) -> Bool {
        !(PDFLexer.isWhitespace(b) || PDFLexer.isDelimiter(b))
    }

    static func write(_ object: PDFObject, to out: inout [UInt8]) {
        switch object {
        case .null: out += Array("null".utf8)
        case .bool(let b): out += Array((b ? "true" : "false").utf8)
        case .integer(let i): out += Array(String(i).utf8)
        case .real(let r): out += Array(r.utf8)
        case .string(let s): write(s, to: &out)
        case .name(let n): write(n, to: &out)
        case .reference(let r): out += Array("\(r.number) \(r.generation) R".utf8)
        case .array(let items):
            out.append(UInt8(ascii: "["))
            for (i, item) in items.enumerated() {
                if i > 0 { out.append(0x20) }
                write(item, to: &out)
            }
            out.append(UInt8(ascii: "]"))
        case .dictionary(let d): write(d, to: &out)
        case .stream(let s):
            var dict = s.dictionary
            dict["Length"] = .integer(s.rawData.count)
            write(dict, to: &out)
            out += Array("\nstream\n".utf8)
            out += s.rawData
            out += Array("\nendstream".utf8)
        }
    }

    static func write(_ d: PDFDictionary, to out: inout [UInt8]) {
        out += Array("<<".utf8)
        for entry in d.entries {
            write(entry.key, to: &out)
            out.append(0x20)
            write(entry.value, to: &out)
            out.append(0x20)
        }
        out += Array(">>".utf8)
    }

    static func write(_ n: PDFName, to out: inout [UInt8]) {
        out.append(UInt8(ascii: "/"))
        for b in n.bytes {
            if b < 0x21 || b > 0x7E || b == UInt8(ascii: "#") || PDFLexer.isDelimiter(b) {
                out += Array(String(format: "#%02X", b).utf8)
            } else {
                out.append(b)
            }
        }
    }

    static func write(_ s: PDFString, to out: inout [UInt8]) {
        if s.isHex {
            out.append(UInt8(ascii: "<"))
            for b in s.bytes { out += Array(String(format: "%02X", b).utf8) }
            out.append(UInt8(ascii: ">"))
            return
        }
        out.append(UInt8(ascii: "("))
        for b in s.bytes {
            switch b {
            case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "\\"):
                out.append(UInt8(ascii: "\\")); out.append(b)
            case 0x0A: out += Array("\\n".utf8)
            case 0x0D: out += Array("\\r".utf8)
            case 0x09: out += Array("\\t".utf8)
            case 0x20...0x7E: out.append(b)
            default: out += Array(String(format: "\\%03o", b).utf8)
            }
        }
        out.append(UInt8(ascii: ")"))
    }

    static func bytes(_ object: PDFObject) -> [UInt8] {
        var out: [UInt8] = []
        write(object, to: &out)
        return out
    }
}

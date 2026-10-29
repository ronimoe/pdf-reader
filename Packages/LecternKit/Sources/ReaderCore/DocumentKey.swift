import CoreGraphics
import CryptoKit
import Foundation

/// A stable key for one PDF, used where state must follow the document's
/// content rather than its path (for now: a password remembered in the
/// Keychain, B6).
///
/// The key is the first element of the trailer's `/ID` as hex, which is
/// readable even while the document is locked. That element survives
/// re-encryption with a different password, so encrypted files also carry a
/// hash of the encryption dictionary's `/O` and `/U` entries: a remembered
/// password can then only ever belong to this exact encryption. Files without
/// an `/ID` (or with an encryption dictionary that can't be read) fall back
/// to a SHA-256 of their first 64 KB. The prefixes record which was used, so
/// the kinds can never collide.
public struct DocumentKey: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(pdfData data: Data) {
        if let key = Self.identifierKey(for: data) {
            rawValue = key
        } else {
            let digest = SHA256.hash(data: data.prefix(Self.fallbackPrefixLength))
            rawValue = "sha256:" + Self.hex(Data(digest))
        }
    }

    public static let fallbackPrefixLength = 64 * 1024

    public var description: String { rawValue }

    private static func identifierKey(for data: Data) -> String? {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              let id = firstIdentifier(of: document)
        else { return nil }
        let key = "id:" + hex(id)
        guard document.isEncrypted else { return key }
        guard let entries = EncryptionDictionary.passwordEntries(in: data) else { return nil }
        return key + ";enc:" + hex(Data(SHA256.hash(data: entries.owner + entries.user)))
    }

    private static func firstIdentifier(of document: CGPDFDocument) -> Data? {
        var string: CGPDFStringRef?
        guard let identifiers = document.fileIdentifier,
              CGPDFArrayGetString(identifiers, 0, &string), let string,
              let bytes = CGPDFStringGetBytePtr(string)
        else { return nil }
        let length = CGPDFStringGetLength(string)
        guard length > 0 else { return nil }
        return Data(bytes: bytes, count: length)
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

/// Reads the `/O` and `/U` strings of a file's standard encryption
/// dictionary straight from its bytes; CoreGraphics doesn't expose the trailer.
/// The encryption dictionary is never compressed into an object stream and its
/// strings are never encrypted, so a small tokenizer is enough.
enum EncryptionDictionary {
    static func passwordEntries(in data: Data) -> (owner: Data, user: Data)? {
        // The last /Encrypt is the newest trailer's (or cross-reference stream's).
        guard let key = data.range(of: Data("/Encrypt".utf8), options: .backwards) else { return nil }
        var scanner = PDFTokenScanner(data[key.upperBound...].prefix(64 * 1024))
        let entries: [String: Data]
        if scanner.peekDictionaryStart() {
            guard let direct = scanner.dictionaryStrings() else { return nil }
            entries = direct
        } else {
            guard let number = scanner.integer(), let generation = scanner.integer(), scanner.keyword() == "R",
                  let object = objectStart(number: number, generation: generation, in: data)
            else { return nil }
            var body = PDFTokenScanner(data[object...].prefix(64 * 1024))
            guard let indirect = body.dictionaryStrings() else { return nil }
            entries = indirect
        }
        guard let owner = entries["O"], let user = entries["U"] else { return nil }
        return (owner, user)
    }

    /// The offset just past `N G obj`, for the last definition of the object.
    private static func objectStart(number: Int, generation: Int, in data: Data) -> Data.Index? {
        let header = Data("\(number) \(generation) obj".utf8)
        var searchEnd = data.endIndex
        while let range = data.range(of: header, options: .backwards, in: data.startIndex..<searchEnd) {
            // "12 0 obj" must not match the tail of "112 0 obj".
            if range.lowerBound == data.startIndex || PDFTokenScanner.isWhitespace(data[range.lowerBound - 1]) {
                return range.upperBound
            }
            searchEnd = range.lowerBound
        }
        return nil
    }
}

/// Just enough PDF tokenizing to read the string entries of one dictionary.
struct PDFTokenScanner {
    private let bytes: [UInt8]
    private var index = 0

    init(_ data: Data) {
        bytes = Array(data)
    }

    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0 || byte == 9 || byte == 10 || byte == 12 || byte == 13 || byte == 32
    }

    private static func isDelimiter(_ byte: UInt8) -> Bool {
        isWhitespace(byte) || Array("()<>[]{}/%".utf8).contains(byte)
    }

    private var current: UInt8? { index < bytes.count ? bytes[index] : nil }

    private func byte(at offset: Int) -> UInt8? {
        index + offset < bytes.count ? bytes[index + offset] : nil
    }

    private mutating func skipWhitespaceAndComments() {
        while let byte = current {
            if Self.isWhitespace(byte) {
                index += 1
            } else if byte == UInt8(ascii: "%") {
                while let next = current, next != 10, next != 13 { index += 1 }
            } else {
                return
            }
        }
    }

    mutating func peekDictionaryStart() -> Bool {
        skipWhitespaceAndComments()
        return current == UInt8(ascii: "<") && byte(at: 1) == UInt8(ascii: "<")
    }

    mutating func keyword() -> String? {
        skipWhitespaceAndComments()
        let start = index
        while let byte = current, !Self.isDelimiter(byte) { index += 1 }
        return index > start ? String(decoding: bytes[start..<index], as: UTF8.self) : nil
    }

    mutating func integer() -> Int? {
        keyword().flatMap { Int($0) }
    }

    /// Parses the dictionary at the current position, returning its entries
    /// whose values are strings (decoded to bytes).
    mutating func dictionaryStrings() -> [String: Data]? {
        guard peekDictionaryStart() else { return nil }
        index += 2
        var result: [String: Data] = [:]
        while true {
            skipWhitespaceAndComments()
            guard let byte = current else { return nil }
            if byte == UInt8(ascii: ">") {
                guard self.byte(at: 1) == UInt8(ascii: ">") else { return nil }
                index += 2
                return result
            }
            guard byte == UInt8(ascii: "/") else { return nil }
            index += 1
            guard let name = keyword() else { return nil }
            switch value() {
            case .string(let data): result[name] = data
            case .other: break
            case .invalid: return nil
            }
        }
    }

    private enum Value {
        case string(Data)
        case other
        case invalid
    }

    private mutating func value() -> Value {
        skipWhitespaceAndComments()
        guard let byte = current else { return .invalid }
        switch byte {
        case UInt8(ascii: "("):
            return literalString().map(Value.string) ?? .invalid
        case UInt8(ascii: "<") where self.byte(at: 1) == UInt8(ascii: "<"):
            return dictionaryStrings() == nil ? .invalid : .other
        case UInt8(ascii: "<"):
            return hexString().map(Value.string) ?? .invalid
        case UInt8(ascii: "["):
            index += 1
            while true {
                skipWhitespaceAndComments()
                guard let next = current else { return .invalid }
                if next == UInt8(ascii: "]") {
                    index += 1
                    return .other
                }
                if case .invalid = value() { return .invalid }
            }
        case UInt8(ascii: "/"):
            index += 1
            _ = keyword()
            return .other
        default:
            // A number or keyword, or a whole reference "N G R".
            guard keyword() != nil else { return .invalid }
            let mark = index
            if integer() != nil, keyword() == "R" { return .other }
            index = mark
            return .other
        }
    }

    private mutating func literalString() -> Data? {
        index += 1
        var output = Data()
        var depth = 1
        while let byte = current {
            index += 1
            switch byte {
            case UInt8(ascii: "\\"):
                guard let escaped = current else { return nil }
                index += 1
                switch escaped {
                case UInt8(ascii: "n"): output.append(10)
                case UInt8(ascii: "r"): output.append(13)
                case UInt8(ascii: "t"): output.append(9)
                case UInt8(ascii: "b"): output.append(8)
                case UInt8(ascii: "f"): output.append(12)
                case 13:
                    // Line continuation: backslash, CR, optional LF.
                    if current == 10 { index += 1 }
                case 10:
                    break
                case UInt8(ascii: "0")...UInt8(ascii: "7"):
                    var value = Int(escaped - UInt8(ascii: "0"))
                    for _ in 0..<2 {
                        guard let digit = current, (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(digit) else { break }
                        value = value * 8 + Int(digit - UInt8(ascii: "0"))
                        index += 1
                    }
                    output.append(UInt8(truncatingIfNeeded: value))
                default:
                    output.append(escaped)
                }
            case UInt8(ascii: "("):
                depth += 1
                output.append(byte)
            case UInt8(ascii: ")"):
                depth -= 1
                if depth == 0 { return output }
                output.append(byte)
            default:
                output.append(byte)
            }
        }
        return nil
    }

    private mutating func hexString() -> Data? {
        index += 1
        var digits: [UInt8] = []
        while let byte = current {
            index += 1
            if byte == UInt8(ascii: ">") {
                if digits.count % 2 == 1 { digits.append(0) }
                var output = Data()
                for pair in stride(from: 0, to: digits.count, by: 2) {
                    output.append(digits[pair] << 4 | digits[pair + 1])
                }
                return output
            }
            if Self.isWhitespace(byte) { continue }
            guard let value = Self.hexValue(byte) else { return nil }
            digits.append(value)
        }
        return nil
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}

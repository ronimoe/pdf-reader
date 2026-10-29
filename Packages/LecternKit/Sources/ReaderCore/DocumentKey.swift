import CoreGraphics
import CryptoKit
import Foundation

/// A stable key for one PDF, used where state must follow the document's
/// content rather than its path (for now: a password remembered in the
/// Keychain, B6).
///
/// The key is the first element of the trailer's `/ID` as hex, which is
/// readable even while the document is locked. Files without an `/ID` fall
/// back to a SHA-256 of their first 64 KB. The prefix records which was used,
/// so the two kinds can never collide.
public struct DocumentKey: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(pdfData data: Data) {
        if let id = Self.firstIdentifier(in: data) {
            rawValue = "id:" + Self.hex(id)
        } else {
            let digest = SHA256.hash(data: data.prefix(Self.fallbackPrefixLength))
            rawValue = "sha256:" + Self.hex(Data(digest))
        }
    }

    public static let fallbackPrefixLength = 64 * 1024

    public var description: String { rawValue }

    private static func firstIdentifier(in data: Data) -> Data? {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              let identifiers = document.fileIdentifier
        else { return nil }
        var string: CGPDFStringRef?
        guard CGPDFArrayGetString(identifiers, 0, &string), let string,
              let bytes = CGPDFStringGetBytePtr(string)
        else { return nil }
        let length = CGPDFStringGetLength(string)
        guard length > 0 else { return nil }
        return Data(bytes: bytes, count: length)
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

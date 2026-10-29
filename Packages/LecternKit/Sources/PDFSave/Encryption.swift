import CommonCrypto
import CryptoKit
import Foundation

/// Why an encrypted file can't be saved into. Everything else the Standard security handler
/// offers is supported (architecture §3.2 item 7, §4.3).
public enum EncryptionProblem: Sendable, Equatable, Hashable {
    /// A security handler other than `/Standard`, such as `/Adobe.PubSec` (certificates).
    case securityHandler(String)
    /// A `/V` and `/R` pair the writer doesn't handle: R5 (Acrobat 9's deprecated AES-256), V3, or
    /// anything unknown.
    case revision(version: Int, revision: Int)
    /// A crypt filter other than `/Identity`, `/V2`, `/AESV2` and `/AESV3`.
    case cryptFilter(String)
    /// No password Lectern holds for the document authenticates against its `/O` and `/U`.
    case passwordNotAuthenticated
    /// The encryption dictionary can't be read.
    case malformed(String)
}

/// How one kind of data (strings, or streams) is encrypted.
enum CryptMethod: Equatable, Sendable {
    case identity
    case rc4
    case aesV2
    case aesV3
}

/// The Standard security handler (ISO 32000-2 §7.6.4), for revisions 2, 3, 4 and 6: the file key,
/// authenticated from a password, and how each object's strings and streams are encrypted.
///
/// Built only by `authenticate`, so no instance ever holds a key that didn't pass the `/U` or `/O`
/// check (and for R6 also `/Perms`).
struct StandardSecurity: Sendable {
    enum Role: Sendable { case user, owner }

    let version: Int
    let revision: Int
    let fileKey: [UInt8]
    let strings: CryptMethod
    let streams: CryptMethod
    /// Named crypt filters, for a stream's own `/Crypt` filter.
    let filters: [PDFName: CryptMethod]
    let encryptMetadata: Bool
    /// `/P` as an unsigned 32-bit value.
    let permissions: UInt32
    /// The `/Encrypt` object, when it is indirect. It is never decrypted or written.
    let dictionaryObject: Int?
    let authenticatedAs: Role

    // MARK: Reading the encryption dictionary

    /// Reads `/Encrypt` and authenticates, trying the password as the user password, then as the
    /// owner password, then the empty user password. Throws `.encrypted` with the reason when the
    /// encryption isn't supported or nothing authenticates.
    static func authenticate(_ dict: PDFDictionary, dictionaryObject: Int?, firstID: [UInt8],
                             password: String?) throws(PDFSaveError) -> StandardSecurity {
        let filter = dict["Filter"]?.nameValue?.string ?? ""
        guard filter == "Standard" else { throw .encrypted(.securityHandler(filter.isEmpty ? "none" : filter)) }
        var v = 0
        if let value = dict["V"] {
            guard let i = value.intValue else { throw .encrypted(.malformed("/V is not an integer")) }
            v = i
        }
        guard let r = dict["R"]?.intValue else { throw .encrypted(.malformed("/R is missing or not an integer")) }
        switch (v, r) {
        case (1, 2), (2, 3), (4, 4), (5, 6): break
        default: throw .encrypted(.revision(version: v, revision: r))
        }
        guard let pValue = dict["P"]?.intValue, pValue >= Int(Int32.min), pValue <= Int(UInt32.max) else {
            throw .encrypted(.malformed("/P is missing or out of range"))
        }
        let permissions = UInt32(truncatingIfNeeded: pValue)
        var encryptMetadata = true
        if let m = dict["EncryptMetadata"] {
            guard case .bool(let b) = m else { throw .encrypted(.malformed("/EncryptMetadata is not a boolean")) }
            encryptMetadata = b
        }

        // Key length in bytes, and the string and stream methods.
        var keyLength = 5
        var strings = CryptMethod.rc4, streams = CryptMethod.rc4
        var filters: [PDFName: CryptMethod] = ["Identity": .identity]
        switch v {
        case 1:
            keyLength = 5
        case 2:
            keyLength = try bits(dict["Length"], default: 40)
        case 4, 5:
            if v == 4 { keyLength = try bits(dict["Length"], default: 128) } else { keyLength = 32 }
            if let cf = dict["CF"] {
                guard let cfDict = cf.dictionaryValue else { throw .encrypted(.malformed("/CF is not a dictionary")) }
                for entry in cfDict.entries {
                    guard let f = entry.value.dictionaryValue else { throw .encrypted(.malformed("crypt filter \(entry.key) is not a dictionary")) }
                    filters[entry.key] = try method(of: f, name: entry.key.string, version: v)
                }
            }
            func named(_ key: PDFName) throws(PDFSaveError) -> CryptMethod {
                guard let value = dict[key] else { return .identity }
                guard let name = value.nameValue else { throw .encrypted(.malformed("/\(key.string) is not a name")) }
                guard let m = filters[name] else { throw .encrypted(.cryptFilter(name.string)) }
                return m
            }
            strings = try named("StrF")
            streams = try named("StmF")
            if v == 4, [strings, streams].contains(.aesV2) { keyLength = 16 }
        default:
            throw .encrypted(.revision(version: v, revision: r))
        }
        if r == 6, [strings, streams].contains(where: { $0 == .rc4 || $0 == .aesV2 }) {
            throw .encrypted(.cryptFilter("V2 or AESV2 under revision 6"))
        }

        func string(_ key: PDFName, count: Int) throws(PDFSaveError) -> [UInt8] {
            guard let s = dict[key]?.stringValue?.bytes, s.count >= count else {
                throw .encrypted(.malformed("/\(key.string) is missing or shorter than \(count) bytes"))
            }
            return Array(s.prefix(count))
        }

        let candidates: [(String, Role)] = {
            var c: [(String, Role)] = []
            if let password { c += [(password, .user), (password, .owner)] }
            if password != "" { c.append(("", .user)) }
            return c
        }()

        if r == 6 {
            let o = try string("O", count: 48), u = try string("U", count: 48)
            let oe = try string("OE", count: 32), ue = try string("UE", count: 32)
            let perms = try string("Perms", count: 16)
            for (candidate, role) in candidates {
                for pw in Password.revision6(candidate) {
                    let key: [UInt8]?
                    switch role {
                    case .owner:
                        guard Hash2B.compute(password: pw, salt: Array(o[32..<40]), userKey: u) == Array(o[0..<32]) else { continue }
                        let intermediate = Hash2B.compute(password: pw, salt: Array(o[40..<48]), userKey: u)
                        key = Crypto.aes(.decrypt, mode: .cbc, key: intermediate, iv: [UInt8](repeating: 0, count: 16), data: oe, padding: false)
                    case .user:
                        guard Hash2B.compute(password: pw, salt: Array(u[32..<40]), userKey: []) == Array(u[0..<32]) else { continue }
                        let intermediate = Hash2B.compute(password: pw, salt: Array(u[40..<48]), userKey: [])
                        key = Crypto.aes(.decrypt, mode: .cbc, key: intermediate, iv: [UInt8](repeating: 0, count: 16), data: ue, padding: false)
                    }
                    guard let key, key.count == 32 else { continue }
                    // /Perms: the permissions and EncryptMetadata, encrypted with the file key. A key
                    // that doesn't decrypt them to what the dictionary says isn't used.
                    guard let p = Crypto.aes(.decrypt, mode: .ecb, key: key, iv: [], data: perms, padding: false),
                          p.count == 16, p[9] == UInt8(ascii: "a"), p[10] == UInt8(ascii: "d"), p[11] == UInt8(ascii: "b"),
                          UInt32(p[0]) | UInt32(p[1]) << 8 | UInt32(p[2]) << 16 | UInt32(p[3]) << 24 == permissions,
                          p[8] == (encryptMetadata ? UInt8(ascii: "T") : UInt8(ascii: "F"))
                    else { throw .encrypted(.malformed("/Perms doesn't match /P and /EncryptMetadata")) }
                    return StandardSecurity(version: v, revision: r, fileKey: key, strings: strings, streams: streams,
                                            filters: filters, encryptMetadata: encryptMetadata, permissions: permissions,
                                            dictionaryObject: dictionaryObject, authenticatedAs: role)
                }
            }
            throw .encrypted(.passwordNotAuthenticated)
        }

        // R2–R4.
        let o = try string("O", count: 32), u = try string("U", count: 32)
        let n = r == 2 ? 5 : keyLength
        for (candidate, role) in candidates {
            for pw in Password.revision4(candidate) {
                let userPassword: [UInt8]
                switch role {
                case .user:
                    userPassword = pw
                case .owner:
                    // Algorithm 7: the owner password's key decrypts /O to the padded user password.
                    var k = Crypto.md5(Password.padded(pw))
                    if r >= 3 { for _ in 0..<50 { k = Crypto.md5(k) } }
                    let rc4Key = Array(k.prefix(n))
                    if r == 2 {
                        userPassword = Crypto.rc4(key: rc4Key, data: o)
                    } else {
                        var x = o
                        for i in stride(from: 19, through: 0, by: -1) {
                            x = Crypto.rc4(key: rc4Key.map { $0 ^ UInt8(i) }, data: x)
                        }
                        userPassword = x
                    }
                }
                let key = fileKey(revision: r, length: n, password: userPassword, o: o, permissions: permissions,
                                  firstID: firstID, encryptMetadata: encryptMetadata)
                // Algorithm 6: the key must reproduce /U.
                let matches: Bool
                if r == 2 {
                    matches = Crypto.rc4(key: key, data: Password.padding) == u
                } else {
                    var x = Crypto.md5(Password.padding + firstID)
                    for i in 0..<20 { x = Crypto.rc4(key: key.map { $0 ^ UInt8(i) }, data: x) }
                    matches = x == Array(u.prefix(16))
                }
                guard matches else { continue }
                return StandardSecurity(version: v, revision: r, fileKey: key, strings: strings, streams: streams,
                                        filters: filters, encryptMetadata: encryptMetadata, permissions: permissions,
                                        dictionaryObject: dictionaryObject, authenticatedAs: role)
            }
        }
        throw .encrypted(.passwordNotAuthenticated)
    }

    /// `/Length` in bits (40 to 128, a multiple of 8), as bytes.
    private static func bits(_ value: PDFObject?, default fallback: Int) throws(PDFSaveError) -> Int {
        guard let value else { return fallback / 8 }
        guard let bits = value.intValue, bits >= 40, bits <= 128, bits % 8 == 0 else {
            throw .encrypted(.malformed("/Length is not 40 to 128 bits in steps of 8"))
        }
        return bits / 8
    }

    private static func method(of filter: PDFDictionary, name: String, version: Int) throws(PDFSaveError) -> CryptMethod {
        guard let cfm = filter["CFM"] else { throw .encrypted(.cryptFilter(name)) }
        switch cfm.nameValue?.string {
        case "V2"?: return .rc4
        case "AESV2"?: return .aesV2
        case "AESV3"? where version == 5: return .aesV3
        case "None"?: throw .encrypted(.cryptFilter("\(name) (/CFM /None)"))
        case let other?: throw .encrypted(.cryptFilter(other))
        case nil: throw .encrypted(.malformed("/CFM of \(name) is not a name"))
        }
    }

    /// Algorithm 2.
    static func fileKey(revision: Int, length n: Int, password: [UInt8], o: [UInt8], permissions: UInt32,
                        firstID: [UInt8], encryptMetadata: Bool) -> [UInt8] {
        var input = Password.padded(password) + o
        input += [UInt8(permissions & 0xFF), UInt8(permissions >> 8 & 0xFF), UInt8(permissions >> 16 & 0xFF), UInt8(permissions >> 24)]
        input += firstID
        if revision >= 4, !encryptMetadata { input += [0xFF, 0xFF, 0xFF, 0xFF] }
        var h = Crypto.md5(input)
        if revision >= 3 { for _ in 0..<50 { h = Crypto.md5(Array(h.prefix(n))) } }
        return Array(h.prefix(n))
    }

    // MARK: Objects

    /// Algorithm 1: the key for one object's strings and streams (R6 uses the file key itself).
    func objectKey(_ ref: ObjectRef, _ method: CryptMethod) -> [UInt8] {
        if method == .aesV3 { return fileKey }
        var input = fileKey
        input += [UInt8(ref.number & 0xFF), UInt8(ref.number >> 8 & 0xFF), UInt8(ref.number >> 16 & 0xFF)]
        input += [UInt8(ref.generation & 0xFF), UInt8(ref.generation >> 8 & 0xFF)]
        if method == .aesV2 { input += Array("sAlT".utf8) }
        return Array(Crypto.md5(input).prefix(min(fileKey.count + 5, 16)))
    }

    func decrypt(_ data: [UInt8], ref: ObjectRef, method: CryptMethod) throws(PDFSaveError) -> [UInt8] {
        switch method {
        case .identity: return data
        case .rc4: return Crypto.rc4(key: objectKey(ref, method), data: data)
        case .aesV2, .aesV3:
            // An empty string, or one holding only its IV, is empty.
            if data.count <= 16 { return [] }
            guard data.count % 16 == 0 else { throw .malformed("AES data of \(data.count) bytes in \(ref)") }
            guard let plain = Crypto.aes(.decrypt, mode: .cbc, key: objectKey(ref, method), iv: Array(data[0..<16]),
                                         data: Array(data[16...]), padding: false),
                  let last = plain.last, last >= 1, last <= 16, Int(last) <= plain.count,
                  plain.suffix(Int(last)).allSatisfy({ $0 == last })
            else { throw .malformed("AES data in \(ref) doesn't decrypt") }
            return Array(plain.dropLast(Int(last)))
        }
    }

    func encrypt(_ data: [UInt8], ref: ObjectRef, method: CryptMethod, iv: [UInt8]? = nil) throws(PDFSaveError) -> [UInt8] {
        switch method {
        case .identity: return data
        case .rc4: return Crypto.rc4(key: objectKey(ref, method), data: data)
        case .aesV2, .aesV3:
            let iv = iv ?? Crypto.randomBytes(16)
            let pad = 16 - data.count % 16
            guard let cipher = Crypto.aes(.encrypt, mode: .cbc, key: objectKey(ref, method), iv: iv,
                                          data: data + [UInt8](repeating: UInt8(pad), count: pad), padding: false)
            else { throw .unsupported("AES encryption failed for \(ref)") }
            return iv + cipher
        }
    }

    /// The method for one stream: its own `/Crypt` filter if it has one, no encryption for
    /// metadata when `/EncryptMetadata` is false, otherwise `/StmF`.
    func streamMethod(_ dict: PDFDictionary) throws(PDFSaveError) -> CryptMethod {
        if let crypt = try Self.cryptFilterName(dict) {
            guard let m = filters[crypt] else { throw .encrypted(.cryptFilter(crypt.string)) }
            return m
        }
        if !encryptMetadata, dict["Type"]?.nameValue == "Metadata" { return .identity }
        return streams
    }

    /// The `/Name` of a stream's first filter when that filter is `/Crypt` (default `/Identity`).
    static func cryptFilterName(_ dict: PDFDictionary) throws(PDFSaveError) -> PDFName? {
        let first: PDFName?
        let parms: PDFDictionary?
        switch dict["Filter"] {
        case .name(let n)?: first = n; parms = dict["DecodeParms"]?.dictionaryValue
        case .array(let a)?: first = a.first?.nameValue; parms = dict["DecodeParms"]?.arrayValue?.first?.dictionaryValue
        default: return nil
        }
        guard first == "Crypt" else { return nil }
        guard let name = parms?["Name"] else { return "Identity" }
        guard let n = name.nameValue else { throw .malformed("/Crypt filter /Name is not a name") }
        return n
    }

    /// Decrypts every string and stream of the indirect object `ref`, as read from the file.
    func decrypt(object: PDFObject, ref: ObjectRef) throws(PDFSaveError) -> PDFObject {
        if ref.number == dictionaryObject { return object }
        return try transform(object, ref: ref, encrypting: false)
    }

    /// Encrypts every string and stream of `object`, about to be written as `ref`.
    func encrypt(object: PDFObject, ref: ObjectRef) throws(PDFSaveError) -> PDFObject {
        guard ref.number != dictionaryObject else { throw .unsupported("the writer would overwrite /Encrypt") }
        return try transform(object, ref: ref, encrypting: true)
    }

    private func transform(_ object: PDFObject, ref: ObjectRef, encrypting: Bool, depth: Int = 0) throws(PDFSaveError) -> PDFObject {
        guard depth < 200 else { throw .malformed("nesting too deep in \(ref)") }
        func string(_ s: PDFString) throws(PDFSaveError) -> PDFObject {
            if encrypting {
                return .string(PDFString(bytes: try encrypt(s.bytes, ref: ref, method: strings), isHex: true))
            }
            let plain = try decrypt(s.bytes, ref: ref, method: strings)
            // Written back the way a new string of the same bytes would be, so a decrypted object
            // serialises exactly like the plaintext it was encrypted from.
            return .string(PDFString(bytes: plain, isHex: !plain.allSatisfy { (0x20...0x7E).contains($0) || $0 == 0x0A || $0 == 0x09 }))
        }
        func dictionary(_ d: PDFDictionary) throws(PDFSaveError) -> PDFDictionary {
            // A signature's /Contents is never encrypted (ISO 32000-2 §7.6.2).
            let isSignature = d["Type"]?.nameValue == "Sig" || d["Type"]?.nameValue == "DocTimeStamp" || d["ByteRange"] != nil
            var out = d
            for entry in d.entries {
                if isSignature, entry.key == "Contents" { continue }
                out[entry.key] = try transform(entry.value, ref: ref, encrypting: encrypting, depth: depth + 1)
            }
            return out
        }
        switch object {
        case .string(let s): return try string(s)
        case .array(let items):
            var out: [PDFObject] = []
            out.reserveCapacity(items.count)
            for item in items { out.append(try transform(item, ref: ref, encrypting: encrypting, depth: depth + 1)) }
            return .array(out)
        case .dictionary(let d): return .dictionary(try dictionary(d))
        case .stream(let s):
            // A cross-reference stream is never encrypted, nor are its dictionary's strings.
            if s.dictionary["Type"]?.nameValue == "XRef" {
                guard !encrypting else { throw .unsupported("the writer would encrypt a cross-reference stream") }
                return object
            }
            let method = try streamMethod(s.dictionary)
            let data = encrypting ? try encrypt(s.rawData, ref: ref, method: method) : try decrypt(s.rawData, ref: ref, method: method)
            return .stream(PDFStream(dictionary: try dictionary(s.dictionary), rawData: data))
        default: return object
        }
    }
}

// MARK: - Passwords

enum Password {
    static let padding: [UInt8] = [
        0x28, 0xBF, 0x4E, 0x5E, 0x4E, 0x75, 0x8A, 0x41, 0x64, 0x00, 0x4E, 0x56, 0xFF, 0xFA, 0x01, 0x08,
        0x2E, 0x2E, 0x00, 0xB6, 0xD0, 0x68, 0x3E, 0x80, 0x2F, 0x0C, 0xA9, 0xFE, 0x64, 0x53, 0x69, 0x7A,
    ]

    /// The first 32 bytes of the password followed by the padding string.
    static func padded(_ password: [UInt8]) -> [UInt8] { Array((password.prefix(32) + padding).prefix(32)) }

    /// R2–R4: the password in PDFDocEncoding. A password with characters outside it is tried as
    /// UTF-8 too, which some writers use; only a candidate that authenticates is ever used.
    static func revision4(_ password: String) -> [[UInt8]] {
        var result: [[UInt8]] = []
        if let doc = PDFDocEncoding.encode(password) { result.append(doc) }
        let utf8 = Array(password.utf8)
        if !result.contains(utf8) { result.append(utf8) }
        return result
    }

    /// R6: the password after SASLprep (RFC 4013), in UTF-8, at most 127 bytes. The UTF-8 of the
    /// password as typed is tried as well when SASLprep changes or rejects it.
    static func revision6(_ password: String) -> [[UInt8]] {
        var result: [[UInt8]] = []
        if let prepared = SASLprep.prepare(password) { result.append(Array(Array(prepared.utf8).prefix(127))) }
        let raw = Array(Array(password.utf8).prefix(127))
        if !result.contains(raw) { result.append(raw) }
        return result
    }
}

extension PDFDocEncoding {
    private static let reverse: [UInt32: UInt8] = {
        var map: [UInt32: UInt8] = [:]
        for byte in UInt8(0)...UInt8(255) where byte != 0x7F && byte != 0x9F && byte != 0xAD {
            let scalar = scalar(for: byte).value
            if map[scalar] == nil { map[scalar] = byte }
        }
        return map
    }()

    /// The string in PDFDocEncoding, or nil if a character has no code in it.
    static func encode(_ string: String) -> [UInt8]? {
        var out: [UInt8] = []
        for scalar in string.precomposedStringWithCanonicalMapping.unicodeScalars {
            guard let byte = reverse[scalar.value] else { return nil }
            out.append(byte)
        }
        return out
    }
}

/// SASLprep (RFC 4013, the stringprep profile R6 passwords use): non-ASCII spaces become spaces,
/// "commonly mapped to nothing" characters go, the result is NFKC-normalised, and prohibited
/// characters reject the password. The bidirectional rule isn't checked; it only ever rejects a
/// password, and a rejected one is still tried as typed (`Password.revision6`).
enum SASLprep {
    static func prepare(_ string: String) -> String? {
        var mapped = String.UnicodeScalarView()
        for scalar in string.unicodeScalars {
            if isNonASCIISpace(scalar.value) { mapped.append(" "); continue }
            if mapsToNothing(scalar.value) { continue }
            mapped.append(scalar)
        }
        let normalized = String(mapped).precomposedStringWithCompatibilityMapping
        for scalar in normalized.unicodeScalars where isProhibited(scalar.value) || isNonASCIISpace(scalar.value) {
            return nil
        }
        return normalized
    }

    static func isNonASCIISpace(_ v: UInt32) -> Bool {
        v == 0x00A0 || v == 0x1680 || (0x2000...0x200B).contains(v) || v == 0x202F || v == 0x205F || v == 0x3000
    }

    static func mapsToNothing(_ v: UInt32) -> Bool {
        [0x00AD, 0x034F, 0x1806, 0x180B, 0x180C, 0x180D, 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF].contains(v)
            || (0xFE00...0xFE0F).contains(v)
    }

    static func isProhibited(_ v: UInt32) -> Bool {
        if v < 0x20 || v == 0x7F || (0x80...0x9F).contains(v) { return true }  // C.2.1, C.2.2
        if [0x06DD, 0x070F, 0x180E, 0x200C, 0x200D, 0x2028, 0x2029, 0xFEFF].contains(v) { return true }
        if (0x2060...0x2063).contains(v) || (0x206A...0x206F).contains(v) || (0xFFF9...0xFFFD).contains(v) { return true }
        if (0x1D173...0x1D17A).contains(v) { return true }
        if (0xE000...0xF8FF).contains(v) || (0xF0000...0xFFFFD).contains(v) || (0x100000...0x10FFFD).contains(v) { return true }  // C.3
        if (0xFDD0...0xFDEF).contains(v) || v & 0xFFFE == 0xFFFE { return true }  // C.4
        if (0x2FF0...0x2FFB).contains(v) { return true }  // C.7
        if [0x0340, 0x0341, 0x200E, 0x200F].contains(v) || (0x202A...0x202E).contains(v) { return true }  // C.8
        if v == 0xE0001 || (0xE0020...0xE007F).contains(v) { return true }  // C.9
        return false
    }
}

/// Algorithm 2.B: the R6 password hash.
enum Hash2B {
    static func compute(password: [UInt8], salt: [UInt8], userKey: [UInt8]) -> [UInt8] {
        var k = Array(SHA256.hash(data: password + salt + userKey))
        var round = 0
        while true {
            let block = password + k + userKey
            var k1: [UInt8] = []
            k1.reserveCapacity(block.count * 64)
            for _ in 0..<64 { k1 += block }
            guard let e = Crypto.aes(.encrypt, mode: .cbc, key: Array(k[0..<16]), iv: Array(k[16..<32]), data: k1, padding: false) else {
                return []  // never matches a stored hash
            }
            let sum = e.prefix(16).reduce(0) { $0 + Int($1) }
            switch sum % 3 {
            case 0: k = Array(SHA256.hash(data: e))
            case 1: k = Array(SHA384.hash(data: e))
            default: k = Array(SHA512.hash(data: e))
            }
            round += 1
            if round >= 64, Int(e[e.count - 1]) <= round - 32 { break }
        }
        return Array(k.prefix(32))
    }
}

// MARK: - Primitives

enum Crypto {
    enum Operation { case encrypt, decrypt }
    enum Mode { case cbc, ecb }

    static func md5(_ data: [UInt8]) -> [UInt8] { Array(Insecure.MD5.hash(data: data)) }

    /// AES with CommonCrypto, without padding: the caller pads (PKCS#7) or checks the padding.
    /// Nil on any CommonCrypto error, including a key or data length it rejects.
    static func aes(_ op: Operation, mode: Mode, key: [UInt8], iv: [UInt8], data: [UInt8], padding: Bool) -> [UInt8]? {
        guard [16, 24, 32].contains(key.count), mode == .ecb || iv.count == 16, padding || data.count % 16 == 0 else { return nil }
        var out = [UInt8](repeating: 0, count: data.count + 16)
        var moved = 0
        var options = CCOptions(0)
        if mode == .ecb { options |= CCOptions(kCCOptionECBMode) }
        if padding { options |= CCOptions(kCCOptionPKCS7Padding) }
        let status = CCCrypt(CCOperation(op == .encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), options,
                             key, key.count, mode == .ecb ? nil : iv, data, data.count, &out, out.count, &moved)
        guard status == kCCSuccess else { return nil }
        return Array(out.prefix(moved))
    }

    /// RC4 with CommonCrypto (`kCCAlgorithmRC4`, a stream cipher: encrypting and decrypting are the same).
    static func rc4(key: [UInt8], data: [UInt8]) -> [UInt8] {
        guard !data.isEmpty else { return [] }
        var out = [UInt8](repeating: 0, count: data.count)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmRC4), CCOptions(0),
                             key, key.count, nil, data, data.count, &out, out.count, &moved)
        // A key CommonCrypto rejects (1 to 512 bytes are accepted) gives bytes that authenticate nothing.
        guard status == kCCSuccess, moved == data.count else { return [UInt8](repeating: 0, count: data.count) }
        return out
    }

    static func randomBytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }
    }
}

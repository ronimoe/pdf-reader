import Foundation
import PDFKit
import Testing
@testable import PDFSave

/// One encrypted file in the collection (Tests/Corpus/README.md).
struct EncryptedFixture: Sendable, CustomTestStringConvertible {
    let name: String
    /// The user password, or "" for a file that opens without one.
    let user: String
    var owner = "owner-pass"
    let version: Int
    let revision: Int
    /// What `Saveability` says with the user password (or none).
    var saveability: Saveability = .inPlace
    var testDescription: String { name }
    var path: String { "\(name).pdf" }
    var isSupported: Bool { if case .unsupported = saveability { false } else { true } }
    /// The password a test opens it with: nil for no user password.
    var password: String? { user.isEmpty ? nil : user }

    static let all: [EncryptedFixture] = [
        EncryptedFixture(name: "encrypted-r2-rc4-40", user: "user-pass", version: 1, revision: 2),
        EncryptedFixture(name: "encrypted-r3-rc4-annotated", user: "", version: 2, revision: 3),
        // 56-bit: the owner key's rounds over the first 7 bytes, not all 16 (pdf.js's way).
        EncryptedFixture(name: "encrypted-r3-rc4-56", user: "user-pass", version: 2, revision: 3),
        EncryptedFixture(name: "encrypted-r4-rc4", user: "pässwörd", version: 4, revision: 4),
        EncryptedFixture(name: "encrypted-r4-aes128-objstm", user: "user-pass", version: 4, revision: 4),
        EncryptedFixture(name: "encrypted-r4-cleartext-metadata", user: "", version: 4, revision: 4),
        EncryptedFixture(name: "encrypted-r4-identity-strings", user: "", version: 4, revision: 4),
        EncryptedFixture(name: "encrypted-aes256", user: "user-pass", version: 5, revision: 6),
        EncryptedFixture(name: "encrypted-aes256-owner-only", user: "", version: 5, revision: 6),
        EncryptedFixture(name: "encrypted-r6-objstm-restricted", user: "", version: 5, revision: 6),
        EncryptedFixture(name: "encrypted-r6-unicode", user: "Grüße-ключ", version: 5, revision: 6),
        EncryptedFixture(name: "encrypted-signed", user: "", version: 5, revision: 6, saveability: .copyOnly([.signed])),
        EncryptedFixture(name: "encrypted-r5", user: "user-pass", version: 5, revision: 5,
                         saveability: .unsupported(.encrypted(.revision(version: 5, revision: 5)))),
        EncryptedFixture(name: "encrypted-pubkey", user: "", version: 5, revision: 0,
                         saveability: .unsupported(.encrypted(.securityHandler("Adobe.PubSec")))),
    ]
    static let supported = all.filter(\.isSupported)

    func data() throws -> Data { try Data(contentsOf: Repo.corpus.appending(path: path)) }
}

@Suite struct EncryptionTests {
    // MARK: Authenticating

    @Test(arguments: EncryptedFixture.supported) func theUserPasswordAuthenticates(_ f: EncryptedFixture) throws {
        let doc = try PDFSaveDocument(data: try f.data(), password: f.password)
        let security = try #require(doc.security)
        #expect(security.version == f.version && security.revision == f.revision)
        #expect(security.authenticatedAs == .user)
        #expect(doc.pageCount > 0)
    }

    @Test(arguments: EncryptedFixture.supported) func theOwnerPasswordGivesTheSameKey(_ f: EncryptedFixture) throws {
        let data = try f.data()
        let user = try PDFSaveDocument(data: data, password: f.password)
        let owner = try PDFSaveDocument(data: data, password: f.owner)
        #expect(owner.security?.authenticatedAs == .owner)
        #expect(owner.fileEncryptionKey == user.fileEncryptionKey)
        #expect(owner.fileEncryptionKey != nil)
    }

    @Test(arguments: EncryptedFixture.supported.filter { !$0.user.isEmpty })
    func aWrongPasswordOrNoneIsNotAuthenticated(_ f: EncryptedFixture) throws {
        let data = try f.data()
        #expect(throws: PDFSaveError.encrypted(.passwordNotAuthenticated)) { try PDFSaveDocument(data: data) }
        #expect(throws: PDFSaveError.encrypted(.passwordNotAuthenticated)) { try PDFSaveDocument(data: data, password: "wrong") }
        #expect(Saveability.evaluate(data) == .unsupported(.encrypted(.passwordNotAuthenticated)))
    }

    @Test(arguments: EncryptedFixture.supported.filter(\.user.isEmpty))
    func aFileWithoutAUserPasswordOpensWithAnyOtherPassword(_ f: EncryptedFixture) throws {
        // The empty user password is tried last, so a password that isn't the owner's (a stale
        // session password, say) still reads the file.
        let doc = try PDFSaveDocument(data: try f.data(), password: "not-the-owner-password")
        #expect(doc.security?.authenticatedAs == .user)
    }

    @Test(arguments: EncryptedFixture.all) func saveabilityIsAsExpected(_ f: EncryptedFixture) throws {
        #expect(Saveability.evaluate(try f.data(), password: f.password) == f.saveability)
    }

    /// The independent check on key derivation: qpdf's own file key, for the user and the owner
    /// password. Symmetric mistakes (the same wrong key on write and read) pass every internal check.
    @Test(.enabled(if: Tools.gate(Tools.has("qpdf")), "qpdf not installed"), arguments: EncryptedFixture.supported)
    func theFileKeyIsQpdfs(_ f: EncryptedFixture) throws {
        let data = try f.data()
        for password in [f.user, f.owner] {
            let qpdf = try ExternalQpdf.fileKey(Repo.corpus.appending(path: f.path), password: password)
            let ours = try PDFSaveDocument(data: data, password: password).fileEncryptionKey
            #expect(ours.map { $0.map { String(format: "%02x", $0) }.joined() } == qpdf, "\(f.name) with \(password)")
        }
    }

    // MARK: Passwords

    @Test func revision4PasswordsArePDFDocEncoded() {
        #expect(Password.revision4("pässwörd").first == [0x70, 0xE4, 0x73, 0x73, 0x77, 0xF6, 0x72, 0x64])
        // A decomposed "ä" is composed first.
        #expect(Password.revision4("pa\u{0308}ss").first == [0x70, 0xE4, 0x73, 0x73])
        // Outside PDFDocEncoding: only UTF-8 is left to try.
        #expect(Password.revision4("ключ") == [Array("ключ".utf8)])
        #expect(Password.padded([]) == Password.padding)
        #expect(Password.padded(Array(repeating: 0x41, count: 40)) == Array(repeating: 0x41, count: 32))
    }

    @Test func revision6PasswordsAreSASLpreppedAndTruncated() {
        // Non-ASCII spaces become spaces; soft hyphens go; NFKC applies.
        #expect(SASLprep.prepare("a\u{00A0}b") == "a b")
        #expect(SASLprep.prepare("pass\u{00AD}word") == "password")
        #expect(SASLprep.prepare("\u{2168}") == "IX")
        #expect(SASLprep.prepare("Grüße-ключ") == "Grüße-ключ")
        // Prohibited: control characters and private use.
        #expect(SASLprep.prepare("a\u{0007}") == nil)
        #expect(SASLprep.prepare("\u{E000}") == nil)
        #expect(Password.revision6(String(repeating: "x", count: 200)).allSatisfy { $0.count == 127 })
        // A prohibited password is still tried as typed.
        #expect(Password.revision6("a\u{0007}") == [Array("a\u{0007}".utf8)])
    }

    /// PDFKit (macOS 26) can't unlock a file whose password isn't ASCII, whatever the encoding, while
    /// PDFSave and CoreGraphics can. The app's password prompt goes through PDFKit, so such files
    /// can't be opened in Lectern at all (docs/known-limitations.md). If this starts failing, Apple
    /// fixed it: the app tests for these fixtures can then use the user password.
    @Test(arguments: ["encrypted-r4-rc4", "encrypted-r6-unicode"])
    func pdfKitCantUnlockANonASCIIPassword(_ name: String) throws {
        let f = try #require(EncryptedFixture.all.first { $0.name == name })
        let pdf = try #require(PDFDocument(data: try f.data()))
        #expect(pdf.isLocked)
        #expect(!pdf.unlock(withPassword: f.user))
        #expect(pdf.unlock(withPassword: f.owner))
        #expect(try PDFSaveDocument(data: try f.data(), password: f.user).security?.authenticatedAs == .user)
    }

    // MARK: Reading

    @Test func annotationsFromAnotherAppAreDecrypted() throws {
        let f = try #require(EncryptedFixture.all.first { $0.name == "encrypted-r3-rc4-annotated" })
        let plain = try PDFSaveDocument(data: try Data(contentsOf: Repo.corpus.appending(path: "third-party-annots.pdf")))
        let doc = try PDFSaveDocument(data: try f.data())
        let strip = { (d: AnnotationDescriptor) in "\(d.pageIndex) \(d.subtype) \(d.contents ?? "") \(d.name ?? "") \(d.author ?? "")" }
        #expect(try doc.annotations().map(strip).sorted() == (try plain.annotations().map(strip).sorted()))
        #expect(try doc.annotations().contains { $0.contents?.isEmpty == false })
    }

    @Test func identityStringsAreReadAsTheyAre() throws {
        let doc = try PDFSaveDocument(data: try Data(contentsOf: Repo.corpus.appending(path: "encrypted-r4-identity-strings.pdf")))
        #expect(doc.security?.strings == .identity)
        #expect(doc.security?.streams == .aesV2)
        let notes = try doc.annotations(onPage: 0)
        #expect(notes.map(\.contents) == ["A note in the clear"])
        #expect(notes.map(\.name) == ["other-app-note-1"])
    }

    @Test func cleartextMetadataIsNotDecrypted() throws {
        let doc = try PDFSaveDocument(data: try Data(contentsOf: Repo.corpus.appending(path: "encrypted-r4-cleartext-metadata.pdf")))
        let security = try #require(doc.security)
        #expect(!security.encryptMetadata)
        let root = try #require(doc.trailer["Root"]?.referenceValue)
        let catalog = try #require(try doc.dictionary(root))
        let reference = try #require(catalog["Metadata"])
        guard case .stream(let metadata) = try doc.resolve(reference) else {
            Issue.record("no metadata stream"); return
        }
        #expect(String(decoding: metadata.rawData, as: UTF8.self).contains("cleartext metadata"))
    }

    @Test func objectStreamsAreDecryptedOnce() throws {
        for name in ["encrypted-r4-aes128-objstm", "encrypted-r6-objstm-restricted"] {
            let f = try #require(EncryptedFixture.all.first { $0.name == name })
            let doc = try PDFSaveDocument(data: try f.data(), password: f.password)
            #expect(doc.latestXRefKind == .stream)
            // The pages live in an object stream.
            #expect(doc.pageRefs.contains { if case .compressed? = doc.entry(for: $0.number) { true } else { false } })
            #expect(doc.pageCount == 3)
        }
    }

    @Test func aSignaturesContentsIsNotDecrypted() throws {
        let doc = try PDFSaveDocument(data: try Data(contentsOf: Repo.corpus.appending(path: "encrypted-signed.pdf")))
        #expect(try doc.copyOnlyReasons() == [.signed])
    }

    // MARK: Malformed encryption dictionaries

    /// A minimal file with this `/Encrypt` dictionary.
    static func encrypted(_ dict: String, id: String = "/ID [<0102030405060708090a0b0c0d0e0f10> <00>]") -> Data {
        WriterUnitTests.minimalPDF(trailerExtra: "\(id) /Encrypt << \(dict) >> ")
    }

    static let o32 = "<" + String(repeating: "ab", count: 32) + ">"
    static let o48 = "<" + String(repeating: "ab", count: 48) + ">"

    @Test(arguments: [
        ("/Filter /Adobe.PubSec /V 4 /R 4", PDFSaveError.encrypted(.securityHandler("Adobe.PubSec"))),
        ("/V 4 /R 4", .encrypted(.securityHandler("none"))),
        ("/Filter /Standard /V 3 /R 3 /P -4 /O \(o32) /U \(o32)", .encrypted(.revision(version: 3, revision: 3))),
        ("/Filter /Standard /V 5 /R 5 /P -4", .encrypted(.revision(version: 5, revision: 5))),
        ("/Filter /Standard /V 1 /R 7 /P -4", .encrypted(.revision(version: 1, revision: 7))),
        ("/Filter /Standard /V (x) /R 2", .encrypted(.malformed("/V is not an integer"))),
        ("/Filter /Standard /V 1 /P -4", .encrypted(.malformed("/R is missing or not an integer"))),
        ("/Filter /Standard /V 1 /R 2 /P 99999999999 /O \(o32) /U \(o32)", .encrypted(.malformed("/P is missing or out of range"))),
        ("/Filter /Standard /V 2 /R 3 /P -4 /Length 41 /O \(o32) /U \(o32)", .encrypted(.malformed("/Length is not 40 to 128 bits in steps of 8"))),
        ("/Filter /Standard /V 2 /R 3 /P -4 /Length 4096 /O \(o32) /U \(o32)", .encrypted(.malformed("/Length is not 40 to 128 bits in steps of 8"))),
        ("/Filter /Standard /V 1 /R 2 /P -4 /O <ab> /U \(o32)", .encrypted(.malformed("/O is missing or shorter than 32 bytes"))),
        ("/Filter /Standard /V 1 /R 2 /P -4 /O \(o32)", .encrypted(.malformed("/U is missing or shorter than 32 bytes"))),
        ("/Filter /Standard /V 1 /R 2 /P -4 /O 5 /U \(o32)", .encrypted(.malformed("/O is missing or shorter than 32 bytes"))),
        ("/Filter /Standard /V 4 /R 4 /P -4 /O \(o32) /U \(o32) /CF << /X << /CFM /Custom >> >> /StmF /X /StrF /X",
         .encrypted(.cryptFilter("Custom"))),
        ("/Filter /Standard /V 4 /R 4 /P -4 /O \(o32) /U \(o32) /CF << /X << /CFM /None >> >> /StmF /X",
         .encrypted(.cryptFilter("X (/CFM /None)"))),
        ("/Filter /Standard /V 4 /R 4 /P -4 /O \(o32) /U \(o32) /StmF /Missing", .encrypted(.cryptFilter("Missing"))),
        ("/Filter /Standard /V 4 /R 4 /P -4 /O \(o32) /U \(o32) /CF 5", .encrypted(.malformed("/CF is not a dictionary"))),
        ("/Filter /Standard /V 4 /R 4 /P -4 /O \(o32) /U \(o32) /CF << /X << /CFM /AESV3 >> >> /StmF /X",
         .encrypted(.cryptFilter("AESV3"))),
        ("/Filter /Standard /V 4 /R 4 /P -4 /O \(o32) /U \(o32) /EncryptMetadata 0", .encrypted(.malformed("/EncryptMetadata is not a boolean"))),
        ("/Filter /Standard /V 5 /R 6 /P -4 /O \(o48) /U \(o48) /OE \(o32) /UE \(o32)",
         .encrypted(.malformed("/Perms is missing or shorter than 16 bytes"))),
        ("/Filter /Standard /V 5 /R 6 /P -4 /O \(o32) /U \(o48) /OE \(o32) /UE \(o32) /Perms <00>",
         .encrypted(.malformed("/O is missing or shorter than 48 bytes"))),
        ("/Filter /Standard /V 5 /R 6 /P -4 /O \(o48) /U \(o48) /OE <00> /UE \(o32) /Perms \(o32)",
         .encrypted(.malformed("/OE is missing or shorter than 32 bytes"))),
        ("/Filter /Standard /V 5 /R 6 /P -4 /O \(o48) /U \(o48) /OE \(o32) /UE \(o32) /Perms \(o32) /CF << /S << /CFM /V2 >> >> /StmF /S",
         .encrypted(.cryptFilter("V2 or AESV2 under revision 6"))),
        // Well-formed but no password matches.
        ("/Filter /Standard /V 1 /R 2 /P -4 /O \(o32) /U \(o32)", .encrypted(.passwordNotAuthenticated)),
        ("/Filter /Standard /V 5 /R 6 /P -4 /O \(o48) /U \(o48) /OE \(o32) /UE \(o32) /Perms \(o32)",
         .encrypted(.passwordNotAuthenticated)),
    ] as [(String, PDFSaveError)])
    func malformedEncryptionIsRefusedWithoutTrapping(_ dict: String, _ expected: PDFSaveError) {
        let data = Self.encrypted(dict)
        #expect(throws: expected) { try PDFSaveDocument(data: data, password: "x") }
        #expect(throws: expected) { try IncrementalWriter().saveCopy(original: data, changes: [.testNote], password: "x") }
    }

    @Test func aBadIDIsRefused() {
        let data = Self.encrypted("/Filter /Standard /V 1 /R 2 /P -4 /O \(Self.o32) /U \(Self.o32)", id: "/ID 5")
        #expect(throws: PDFSaveError.encrypted(.malformed("/ID is not an array of strings"))) { try PDFSaveDocument(data: data) }
    }

    @Test func revisionsThatDisagreeOnEncryptionAreRefused() throws {
        // An update whose trailer drops /Encrypt: the writer would otherwise emit an unencrypted
        // trailer over encrypted objects.
        let f = try #require(EncryptedFixture.all.first { $0.name == "encrypted-r2-rc4-40" })
        var data = try f.data()
        let doc = try PDFSaveDocument(data: data, password: f.user)
        let update = "\nxref\n0 0\ntrailer\n<< /Size \(doc.size) /Root \(doc.trailer["Root"]!.referenceValue!) /Prev \(doc.startXRef) >>\nstartxref\n\(data.count + 1)\n%%EOF\n"
        data += Data(update.utf8)
        #expect(throws: PDFSaveError.encrypted(.malformed("an earlier revision has /Encrypt and the newest doesn't"))) {
            try PDFSaveDocument(data: data, password: f.user)
        }
    }

    @Test func anUpdatePointingAtAnotherEncryptDictionaryIsRefused() throws {
        // The original's trailer has /Encrypt N 0 R; an update names another object. Which one
        // counts is a guess, so neither is used.
        let f = try #require(EncryptedFixture.all.first { $0.name == "encrypted-r2-rc4-40" })
        var data = try f.data()
        let doc = try PDFSaveDocument(data: data, password: f.user)
        let original = try #require(doc.trailer["Encrypt"]?.referenceValue)
        let ids = PDFSerializer.bytes(try #require(doc.trailer["ID"]))
        let update = "\nxref\n0 0\ntrailer\n<< /Size \(doc.size) /Root \(doc.trailer["Root"]!.referenceValue!) /Encrypt 99 0 R /ID \(String(decoding: ids, as: UTF8.self)) /Prev \(doc.startXRef) >>\nstartxref\n\(data.count + 1)\n%%EOF\n"
        #expect(original.number != 99)
        data += Data(update.utf8)
        #expect(throws: PDFSaveError.encrypted(.malformed("revisions disagree on /Encrypt"))) {
            try PDFSaveDocument(data: data, password: f.user)
        }
    }

    @Test func anEncryptionDictionaryWithARepeatedKeyIsRefused() throws {
        var dict = PDFDictionary()
        dict["Filter"] = .name("Standard")
        dict["V"] = .integer(4)
        dict.hasDuplicateKeys = true
        #expect(throws: PDFSaveError.encrypted(.malformed("the encryption dictionary repeats a key"))) {
            try StandardSecurity.authenticate(dict, dictionaryObject: nil, firstID: [], password: nil)
        }
    }

    /// R6's /Perms repeats /P and /EncryptMetadata under the file key; a dictionary that says
    /// otherwise than /Perms is refused, even with the right password.
    @Test func r6PermsMustAgreeWithTheDictionary() throws {
        let f = try #require(EncryptedFixture.all.first { $0.name == "encrypted-aes256" })
        let doc = try PDFSaveDocument(data: try f.data(), password: f.user)
        let ref = try #require(doc.trailer["Encrypt"]?.referenceValue)
        let dict = try #require(try doc.dictionary(ref))  // never decrypted
        let firstID = try #require(doc.trailer["ID"]?.arrayValue?.first?.stringValue?.bytes)
        // As written: /Perms says "T" and /EncryptMetadata is absent (true).
        #expect(try StandardSecurity.authenticate(dict, dictionaryObject: ref.number, firstID: firstID, password: f.user).revision == 6)
        var metadataInTheClear = dict
        metadataInTheClear["EncryptMetadata"] = .bool(false)
        #expect(throws: PDFSaveError.encrypted(.malformed("/Perms doesn't match /P and /EncryptMetadata"))) {
            try StandardSecurity.authenticate(metadataInTheClear, dictionaryObject: ref.number, firstID: firstID, password: f.user)
        }
        var otherPermissions = dict
        otherPermissions["P"] = .integer(-3904)
        #expect(throws: PDFSaveError.encrypted(.malformed("/Perms doesn't match /P and /EncryptMetadata"))) {
            try StandardSecurity.authenticate(otherPermissions, dictionaryObject: ref.number, firstID: firstID, password: f.user)
        }
    }

    @Test func aesDataThatDoesntDecryptIsRefused() throws {
        let security = StandardSecurity.testAES
        // Not a multiple of 16, and bad padding.
        #expect(throws: PDFSaveError.self) { try security.decrypt([UInt8](repeating: 1, count: 33), ref: ObjectRef(5), method: .aesV2) }
        #expect(throws: PDFSaveError.self) { try security.decrypt([UInt8](repeating: 1, count: 32), ref: ObjectRef(5), method: .aesV2) }
        // An empty string and an IV alone are empty; 1 to 15 bytes can't be AES output.
        #expect(try security.decrypt([], ref: ObjectRef(5), method: .aesV2) == [])
        #expect(try security.decrypt([UInt8](repeating: 1, count: 16), ref: ObjectRef(5), method: .aesV2) == [])
        for count in 1...15 {
            #expect(throws: PDFSaveError.malformed("AES data of \(count) bytes in 5 0 R")) {
                try security.decrypt([UInt8](repeating: 1, count: count), ref: ObjectRef(5), method: .aesV2)
            }
        }
        // Round trip, with padding of a whole block.
        for count in [0, 1, 15, 16, 17, 100] {
            let plain = (0..<count).map { UInt8($0 & 0xFF) }
            let cipher = try security.encrypt(plain, ref: ObjectRef(7, 2), method: .aesV2)
            #expect(cipher.count == 16 + (count / 16 + 1) * 16)
            #expect(try security.decrypt(cipher, ref: ObjectRef(7, 2), method: .aesV2) == plain)
            // Another object's key doesn't decrypt it to the same bytes.
            #expect((try? security.decrypt(cipher, ref: ObjectRef(8, 2), method: .aesV2)) != plain)
        }
    }

    @Test func objectKeysFollowAlgorithmOne() {
        let s = StandardSecurity.testAES
        // MD5(key + 3 bytes of the number + 2 of the generation + "sAlT"), at most 16 bytes.
        let expected = Crypto.md5(s.fileKey + [0x34, 0x12, 0x00, 0x02, 0x00] + Array("sAlT".utf8))
        #expect(s.objectKey(ObjectRef(0x1234, 2), .aesV2) == expected)
        let rc4 = Crypto.md5(s.fileKey + [0x34, 0x12, 0x00, 0x02, 0x00])
        #expect(s.objectKey(ObjectRef(0x1234, 2), .rc4) == rc4)
        #expect(s.objectKey(ObjectRef(0x1234, 2), .aesV3) == s.fileKey)
    }

    // MARK: Writing

    static func highlight(_ f: EncryptedFixture) throws -> AnnotationChange {
        let pk = try #require(PDFDocument(data: try f.data()))
        if pk.isLocked { #expect(pk.unlock(withPassword: f.owner)) }
        return .addMarkup(NewMarkup(kind: .highlight, pageIndex: 0, quads: try Corpus.quads(pk, page: 0),
                                    contents: "Read me back", name: Corpus.name(9)))
    }

    /// A wrong key gives the right number of annotations with garbage text. The writer's own
    /// verification and the app's read-back check must both catch it.
    @Test(arguments: ["encrypted-r2-rc4-40", "encrypted-r4-aes128-objstm", "encrypted-aes256"])
    func aWrongObjectKeyIsCaught(_ name: String) throws {
        let f = try #require(EncryptedFixture.all.first { $0.name == name })
        let data = try f.data()
        var options = IncrementalWriter.Options(verify: false)
        options.testHooks.encryptWithKeyOf = { ref in ObjectRef(ref.number + 1, ref.generation) }
        let result = try IncrementalWriter(options: options).saveInPlace(original: data, changes: [try Self.highlight(f)], password: f.password)
        if f.revision < 6 {
            // R6 uses the file key for every object, so only R2–R4 can get an object key wrong.
            #expect(throws: PDFSaveError.self) { try SavedFileCheck.verify(result.data, original: data, against: result, password: f.password) }
            options.verify = true
            #expect(throws: PDFSaveError.self) {
                try IncrementalWriter(options: options).saveInPlace(original: data, changes: [try Self.highlight(f)], password: f.password)
            }
        }
        if f.revision == 2 {
            // RC4: the count is right and only the text is wrong, which counting alone would miss.
            let before = try PDFSaveDocument(data: data, password: f.password).annotations()
            let after = try PDFSaveDocument(data: result.data, password: f.password).annotations()
            #expect(after.count == before.count + 1)
            #expect(!after.contains { $0.contents == "Read me back" })
        }
    }

    @Test func savedFileCheckComparesTextNotJustCounts() throws {
        // A plain file: rewrite the added annotation's /Contents after the expected state is fixed.
        let data = try Data(contentsOf: Repo.corpus.appending(path: "classic-xref.pdf"))
        let pk = try #require(PDFDocument(data: data))
        var options = IncrementalWriter.Options(verify: false)
        options.testHooks.mutateWritten = { objects in
            for (ref, object) in objects {
                if var d = object.dictionaryValue, d["Subtype"] == .name("Highlight") {
                    d["Contents"] = .text("Garbage")
                    objects[ref] = .dictionary(d)
                }
            }
        }
        let change = AnnotationChange.addMarkup(NewMarkup(kind: .highlight, pageIndex: 0, quads: try Corpus.quads(pk, page: 0), contents: "Right"))
        let result = try IncrementalWriter(options: options).saveInPlace(original: data, changes: [change])
        #expect(throws: PDFSaveError.verificationFailed("annotation \(result.added[0].ref) doesn't read back as written")) {
            try SavedFileCheck.verify(result.data, original: data, against: result)
        }
    }

    /// An existing annotation the update rewrites without saying so (not added, not edited): the
    /// read-back must compare it with the original, not just count it.
    @Test func savedFileCheckCatchesAnUndeclaredChangeToAnExistingAnnotation() throws {
        let data = try Data(contentsOf: Repo.corpus.appending(path: "third-party-annots.pdf"))
        let doc = try PDFSaveDocument(data: data)
        let square = try Corpus.find(doc, page: 0, subtype: "Square")
        var changed = try #require(try doc.dictionary(square))
        changed["Contents"] = .text("Rewritten behind the check's back")
        let rewritten = PDFObject.dictionary(changed)
        var options = IncrementalWriter.Options(verify: false)
        options.testHooks.mutateWritten = { objects in objects[square] = rewritten }
        let pk = try #require(PDFDocument(data: data))
        let change = AnnotationChange.addMarkup(NewMarkup(kind: .highlight, pageIndex: 0, quads: try Corpus.quads(pk, page: 0), contents: "Added"))
        let result = try IncrementalWriter(options: options).saveInPlace(original: data, changes: [change])
        #expect(result.writtenAnnotations[square] == nil)
        #expect(throws: PDFSaveError.verificationFailed("annotation \(square) reads back differently from the original")) {
            try SavedFileCheck.verify(result.data, original: data, against: result)
        }
    }

    @Test func savedFileCheckNeedsThePassword() throws {
        let f = try #require(EncryptedFixture.all.first { $0.name == "encrypted-aes256" })
        let data = try f.data()
        let result = try IncrementalWriter().saveInPlace(original: data, changes: [try Self.highlight(f)], password: f.password)
        #expect(try SavedFileCheck.verify(result.data, original: data, against: result, password: f.password).contains { $0.contents == "Read me back" })
        #expect(throws: PDFSaveError.self) { try SavedFileCheck.verify(result.data, original: data, against: result) }
    }

    @Test func aesIVsAreRandomAndStringsAreHex() throws {
        let f = try #require(EncryptedFixture.all.first { $0.name == "encrypted-r4-aes128-objstm" })
        let data = try f.data()
        let a = try IncrementalWriter().saveInPlace(original: data, changes: [try Self.highlight(f)], password: f.password)
        let b = try IncrementalWriter().saveInPlace(original: data, changes: [try Self.highlight(f)], password: f.password)
        #expect(a.data != b.data)
        let update = String(decoding: a.data.suffix(from: data.count), as: UTF8.self)
        #expect(!update.contains("(Read me back)") && !update.contains("Read me back"))
        #expect(!update.contains(Corpus.name(9)))
    }

    @Test func theWriterNeverTouchesEncryptOrTheXRefStream() throws {
        let s = StandardSecurity.testAES
        let encryptObject = StandardSecurity(version: 4, revision: 4, fileKey: s.fileKey, strings: .aesV2, streams: .aesV2, filters: s.filters,
                                             encryptMetadata: true, permissions: s.permissions, dictionaryObject: 12, authenticatedAs: .user)
        #expect(throws: PDFSaveError.unsupported("the writer would overwrite /Encrypt")) {
            try encryptObject.encrypt(object: .dictionary([:]), ref: ObjectRef(12))
        }
        let xref = PDFObject.stream(PDFStream(dictionary: ["Type": .name("XRef")], rawData: [1, 2, 3]))
        #expect(throws: PDFSaveError.unsupported("the writer would encrypt a cross-reference stream")) {
            try s.encrypt(object: xref, ref: ObjectRef(3))
        }
        // Reading leaves both alone.
        #expect(try s.decrypt(object: xref, ref: ObjectRef(3)) == xref)
        let raw = PDFObject.dictionary(["O": .string(PDFString(bytes: [1, 2, 3]))])
        #expect(try encryptObject.decrypt(object: raw, ref: ObjectRef(12)) == raw)
    }

    @Test func aSignaturesContentsIsLeftAloneBothWays() throws {
        let s = StandardSecurity.testAES
        let sig = PDFObject.dictionary(["Type": .name("Sig"), "Contents": .string(PDFString(bytes: [0xAB, 0xCD], isHex: true)),
                                        "Reason": .string(PDFString(bytes: Array("ok".utf8)))])
        let encrypted = try s.encrypt(object: sig, ref: ObjectRef(4))
        #expect(encrypted.dictionaryValue?["Contents"] == sig.dictionaryValue?["Contents"])
        #expect(encrypted.dictionaryValue?["Reason"] != sig.dictionaryValue?["Reason"])
        #expect(try s.decrypt(object: encrypted, ref: ObjectRef(4)) == sig)
    }

    @Test func aStreamsOwnCryptFilterIsHonoured() throws {
        let s = StandardSecurity.testAES
        let identity: PDFDictionary = ["Filter": .array([.name("Crypt")]), "DecodeParms": .array([.dictionary(["Name": .name("Identity")])])]
        #expect(try s.streamMethod(identity) == .identity)
        #expect(try s.streamMethod(["Filter": .name("Crypt")]) == .identity)
        #expect(throws: PDFSaveError.encrypted(.cryptFilter("Custom"))) {
            try s.streamMethod(["Filter": .name("Crypt"), "DecodeParms": .dictionary(["Name": .name("Custom")])])
        }
        #expect(try s.streamMethod(["Type": .name("Metadata")]) == .aesV2)
    }

    // MARK: Apple's own encryption

    /// The encrypted PDFs most Mac users have come from macOS itself (Preview, Print ▸ Save as
    /// PDF), written by CoreGraphics or PDFKit. Make some here, then check PDFSave gets qpdf's key
    /// for the user and the owner password, saves into them, and qpdf accepts the result.
    enum AppleWriter: String, CaseIterable, Sendable { case coreGraphics40, coreGraphics128, pdfKit }

    static func appleEncrypted(_ writer: AppleWriter, user: String?) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        var info: [CFString: Any] = [kCGPDFContextOwnerPassword: "owner-pass"]
        if let user { info[kCGPDFContextUserPassword] = user }
        switch writer {
        case .coreGraphics40: info[kCGPDFContextEncryptionKeyLength] = 40
        case .coreGraphics128, .pdfKit: info[kCGPDFContextEncryptionKeyLength] = 128
        }
        let plain = writer == .pdfKit
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, plain ? nil : info as CFDictionary))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 72, y: 700, width: 200, height: 20))
        context.endPDFPage()
        context.closePDF()
        guard plain else { return data as Data }
        // Preview's route: PDFKit's own write with passwords.
        let document = try #require(PDFDocument(data: data as Data))
        var options: [PDFDocumentWriteOption: Any] = [.ownerPasswordOption: "owner-pass"]
        if let user { options[.userPasswordOption] = user }
        let url = FileManager.default.temporaryDirectory.appending(path: "lectern-apple-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try #require(document.write(to: url, withOptions: options))
        return try Data(contentsOf: url)
    }

    @Test(.enabled(if: Tools.gate(Tools.has("qpdf")), "qpdf not installed"),
          arguments: AppleWriter.allCases, [nil, "user-pass"] as [String?])
    func applesEncryptionIsReadAndWritten(_ writer: AppleWriter, _ user: String?) throws {
        let data = try Self.appleEncrypted(writer, user: user)
        let url = FileManager.default.temporaryDirectory.appending(path: "lectern-apple-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        let doc = try PDFSaveDocument(data: data, password: user)
        let security = try #require(doc.security)
        print("Apple \(writer) user=\(user ?? "-"): V\(security.version) R\(security.revision) key \(security.fileKey.count) bytes, strings \(security.strings), streams \(security.streams)")
        let userKey = try #require(doc.fileEncryptionKey).map { String(format: "%02x", $0) }.joined()
        #expect(try ExternalQpdf.fileKey(url, password: user ?? "") == userKey)
        // The owner password gives the same key, except on CoreGraphics' 40-bit files: their /O
        // doesn't decrypt with the owner password in any reader (PDFKit and CoreGraphics
        // themselves, qpdf, MuPDF, pikepdf all refuse it), so only the user password opens them.
        if writer == .coreGraphics40 {
            if user != nil {
                #expect(throws: PDFSaveError.encrypted(.passwordNotAuthenticated)) { try PDFSaveDocument(data: data, password: "owner-pass") }
                let pk = try #require(PDFDocument(data: data))
                #expect(!pk.unlock(withPassword: "owner-pass"))
            }
        } else {
            let owner = try PDFSaveDocument(data: data, password: "owner-pass")
            #expect(owner.security?.authenticatedAs == .owner)
            #expect(owner.fileEncryptionKey == doc.fileEncryptionKey)
            #expect(try ExternalQpdf.fileKey(url, password: "owner-pass") == userKey)
        }
        let result = try IncrementalWriter().saveInPlace(original: data, changes: [
            .addNote(NewNote(pageIndex: 0, origin: PDFPoint(x: 300, y: 300), contents: "Note in Apple's encryption")),
        ], password: user)
        try SavedFileCheck.verify(result.data, original: data, against: result, password: user)
        let out = url.deletingPathExtension().appendingPathExtension("saved.pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try result.data.write(to: out)
        try Qpdf.run(["--check", out.path], password: user ?? "owner-pass")
        // PDFKit reads the note back with the password.
        let pk = try #require(PDFDocument(data: result.data))
        if pk.isLocked { #expect(pk.unlock(withPassword: user ?? "")) }
        #expect(pk.page(at: 0)?.annotations.contains { $0.contents == "Note in Apple's encryption" } == true)
    }

    @Test func rc4MatchesAKnownVector() {
        // RFC 6229 is for longer keys; this is the classic "Key"/"Plaintext" vector.
        #expect(Crypto.rc4(key: Array("Key".utf8), data: Array("Plaintext".utf8))
                == [0xBB, 0xF3, 0x16, 0xE8, 0xD9, 0x40, 0xAF, 0x0A, 0xD3])
    }
}

extension AnnotationChange {
    /// The `/Contents` an add or a contents edit writes.
    var addedContents: String? {
        switch self {
        case .addMarkup(let m): m.contents
        case .addNote(let n): n.contents
        case .editContents(_, let text): text
        default: nil
        }
    }
}

extension StandardSecurity {
    static let testAES = StandardSecurity(version: 4, revision: 4, fileKey: Array(0..<16), strings: .aesV2, streams: .aesV2,
                                          filters: ["Identity": .identity], encryptMetadata: true, permissions: 0xFFFF_FFFC,
                                          dictionaryObject: nil, authenticatedAs: .user)
}

enum ExternalQpdf {
    /// `qpdf --show-encryption-key`'s file key, as lowercase hex.
    static func fileKey(_ url: URL, password: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try #require(Tools.path("qpdf")))
        // Through a file: Foundation's `Process` decomposes non-ASCII arguments.
        let file = FileManager.default.temporaryDirectory.appending(path: "lectern-pw-\(UUID().uuidString)")
        try Data((password + "\n").utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        process.arguments = ["--show-encryption", "--show-encryption-key", "--password-file=\(file.path)", url.path]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        let line = try #require(text.split(separator: "\n").first { $0.hasPrefix("Encryption key = ") })
        return String(line.dropFirst("Encryption key = ".count)).trimmingCharacters(in: .whitespaces)
    }
}

import Foundation
import PDFKit
import Testing
@testable import PDFSave

enum Repo {
    /// Packages/LecternKit/Tests/PDFSaveTests/<file> → repository root.
    static let root: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }()

    static let corpus = root.appending(path: "Tests/Corpus/public")
    static let realWorld = corpus.appending(path: "realworld")
    static let verifyScript = root.appending(path: "scripts/corpus/verify")
    static let venvPython = root.appending(path: ".venv/bin/python")
    static let pdfjs = root.appending(path: "scripts/corpus/node_modules/pdfjs-dist")

    /// `$TMPDIR/lectern-corpus-<checkout folder>`: one directory per checkout, so test runs in
    /// several git worktrees at once don't overwrite each other's outputs and manifest.
    static let outputDirectory: URL = {
        if let custom = ProcessInfo.processInfo.environment["LECTERN_CORPUS_OUT"] { return URL(fileURLWithPath: custom) }
        return FileManager.default.temporaryDirectory.appending(path: "lectern-corpus-\(root.lastPathComponent)")
    }()
}

enum Tools {
    static func path(_ name: String) -> String? {
        let env = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let dirs = env.split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        return dirs.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func has(_ names: String...) -> Bool { names.allSatisfy { path($0) != nil } }
    static var venv: Bool { FileManager.default.isExecutableFile(atPath: Repo.venvPython.path) }

    /// Set by scripts/test.sh: a missing tool fails the external checks instead of skipping them.
    static var required: Bool { ProcessInfo.processInfo.environment["LECTERN_REQUIRE_TOOLS"] == "1" }
    /// Whether a gated test runs: when its tools are present, or always when tools are required.
    static func gate(_ available: Bool) -> Bool { available || required }

    static var qpdfCheck: Bool { has("qpdf", "python3") }
    static var objectsCheck: Bool { venv && has("qpdf") }
    static var mupdfCheck: Bool { venv && has("mutool") }
    static var popplerCheck: Bool { venv && has("pdftoppm") }
    /// pdf.js listing and rendering: node, pdfjs-dist, its optional canvas backend, and Pillow from the venv.
    static var pdfjs: Bool {
        let canvas = Repo.root.appending(path: "scripts/corpus/node_modules/@napi-rs/canvas")
        return FileManager.default.fileExists(atPath: Repo.pdfjs.path) && FileManager.default.fileExists(atPath: canvas.path)
            && has("node") && venv
    }
}

/// One corpus scenario: an input file and the changes the writer applies to it.
struct CorpusCase: Sendable, CustomTestStringConvertible {
    let name: String
    /// A path under Tests/Corpus/public, "@<case>" to start from another case's output (a second
    /// save), or "~<case>" for the plaintext twin of an encrypted case's input (`qpdf --decrypt`).
    let input: String
    /// What `Saveability.evaluate` must say about the input. `copyOnly` cases are saved with
    /// `saveCopy`, and `saveInPlace` must refuse them; `unsupported` ones must fail to save at all.
    var saveability: Saveability = .inPlace
    var appearanceStreams = true
    /// The password PDFSave and the external tools open an encrypted input with (nil: none).
    var password: String?
    /// The password PDFKit unlocks it with, when that differs: PDFKit can't unlock a non-ASCII
    /// password (EncryptionTests), so those files use the owner password there.
    var pdfKitPassword: String?
    let changes: @Sendable (PDFSaveDocument, PDFDocument) throws -> [AnnotationChange]

    var testDescription: String { name }
    var isRefused: Bool { if case .unsupported = saveability { true } else { false } }
    /// The encrypted case this one is the plaintext twin of (the strong oracle, CorpusTests).
    var twinOf: String? { name.hasSuffix(".twin") ? String(name.dropLast(".twin".count)) : nil }
    var isTwin: Bool { twinOf != nil }
}

/// What a render probe looks for inside `rect`.
enum ProbeKind: String, Sendable {
    /// The whole area is tinted: the mean blue channel drops by at least 40.
    case fill = "highlight"
    /// A thin coloured line: more strongly tinted pixels than before (see CorpusTests).
    case line = "line"
}

/// The result of running one case, shared by all tests.
struct CorpusOutcome: Sendable {
    let testCase: CorpusCase
    let inputURL: URL
    let outputURL: URL?
    let result: SaveResult?
    let error: PDFSaveError?
    let changes: [AnnotationChange]
    /// Annotations the writer removed or edited, read before the save.
    let removedInfo: [AnnotationDescriptor]
    let editedInfo: [AnnotationDescriptor]
    /// Expected change to PDFKit's per-page list of "Type|Contents" keys.
    var pdfKitRemoved: [(page: Int, key: String)] = []
    var pdfKitAdded: [(page: Int, key: String)] = []
    var probes: [(page: Int, rect: PDFRect, kind: ProbeKind)] = []
    /// Why the case couldn't run at all (its input file is missing). Only this case fails then;
    /// the others still run.
    var problem: String?
}

enum Corpus {
    static let author = "Lectern Tester"
    static let red = PDFRGBColor(red: 1, green: 0, blue: 0)
    static let green = PDFRGBColor(red: 0.2, green: 0.8, blue: 0.2)

    static func key(_ type: String, _ contents: String?) -> String { "\(type)|\(contents ?? "")" }

    /// Quads covering the first match of `phrase` on `page`, found with PDFKit (test code only).
    static func quads(_ doc: PDFDocument, page index: Int, phrase: String = "Lectern test corpus") throws -> [Quad] {
        guard let page = doc.page(at: index) else { throw CorpusFailure("no page \(index)") }
        let matches = doc.findString(phrase, withOptions: []).filter { $0.pages.first == page }
        guard let match = matches.first else { throw CorpusFailure("'\(phrase)' not found on page \(index)") }
        return match.selectionsByLine().map { line in
            let b = line.bounds(for: page)
            return Quad(rect: PDFRect(x: b.minX, y: b.minY, width: b.width, height: b.height))
        }
    }

    /// One quad over the `n`-th text line on `page` that is at least 120 pt wide and clear of
    /// `avoiding` (so a line probe never sees another annotation's colour), so files don't need
    /// hand-picked phrases for underlines and strike-outs.
    static func lineQuad(_ doc: PDFDocument, page index: Int, line n: Int, avoiding: [Quad] = []) throws -> [Quad] {
        guard let page = doc.page(at: index), let all = page.selection(for: page.bounds(for: .mediaBox)) else {
            throw CorpusFailure("no text on page \(index)")
        }
        let taken = avoiding.map { q in CGRect(x: q.bounds.x, y: q.bounds.y, width: q.bounds.width, height: q.bounds.height).insetBy(dx: -4, dy: -4) }
        let lines = all.selectionsByLine().map { $0.bounds(for: page) }
            .filter { $0.width >= 120 && $0.height >= 6 && $0.height <= 30 }
            .filter { line in !taken.contains { $0.intersects(line) } }
        guard lines.count > n else { throw CorpusFailure("page \(index) has only \(lines.count) wide lines") }
        let b = lines[n]
        return [Quad(rect: PDFRect(x: b.minX, y: b.minY, width: b.width, height: b.height))]
    }

    static func highlight(_ doc: PDFDocument, page: Int, _ contents: String,
                          phrase: String = "Lectern test corpus") throws -> AnnotationChange {
        .addMarkup(NewMarkup(kind: .highlight, pageIndex: page, quads: try quads(doc, page: page, phrase: phrase),
                             contents: contents, author: author))
    }

    static func markup(_ kind: MarkupKind, _ doc: PDFDocument, page: Int, line: Int, _ contents: String?,
                       avoiding: [Quad] = []) throws -> AnnotationChange {
        .addMarkup(NewMarkup(kind: kind, pageIndex: page, quads: try lineQuad(doc, page: page, line: line, avoiding: avoiding),
                             color: red, contents: contents))
    }

    static func note(_ doc: PDFDocument, page: Int, _ contents: String) -> AnnotationChange {
        let box = doc.page(at: page)!.bounds(for: .mediaBox)
        return .addNote(NewNote(pageIndex: page, origin: PDFPoint(x: box.maxX - 60, y: box.maxY - 60),
                                contents: contents, author: author))
    }

    static func find(_ doc: PDFSaveDocument, page: Int, subtype: String, contents: String? = nil,
                     lectern: Bool? = nil) throws -> ObjectRef {
        let match = try doc.annotations(onPage: page).first {
            $0.subtype == subtype && (contents == nil || $0.contents == contents) && (lectern == nil || $0.isLectern == lectern)
        }
        guard let ref = match?.ref else { throw CorpusFailure("no \(subtype) annotation on page \(page)") }
        return ref
    }

    /// A real-world file: a highlight on a known phrase, an underline and a strike-out on wide text
    /// lines, and a note.
    static func realWorld(_ name: String, phrase: String, page: Int = 1, folder: String = "realworld",
                          saveability: Saveability = .inPlace) -> CorpusCase {
        CorpusCase(name: name, input: "\(folder)/\(name).pdf", saveability: saveability) { _, pk in
            let highlighted = try quads(pk, page: page, phrase: phrase)
            return [.addMarkup(NewMarkup(kind: .highlight, pageIndex: page, quads: highlighted, contents: "Highlight on \(name)",
                                         author: author)),
                    try markup(.underline, pk, page: page, line: 2, "Underline on \(name)", avoiding: highlighted),
                    try markup(.strikeOut, pk, page: page, line: 4, nil, avoiding: highlighted),
                    note(pk, page: 0, "Note on \(name)")]
        }
    }

    /// Every case. Files under `fetched/` exist only after `scripts/corpus/bootstrap`; without them
    /// their cases are left out, unless tools are required (`scripts/test.sh`), where a missing
    /// file fails the run. The plaintext twins need qpdf, and are left out without it unless tools
    /// are required.
    static let cases: [CorpusCase] = allCases.filter { c in
        if c.isTwin || c.input.hasPrefix("@") && allCases.first(where: { "@" + $0.name == c.input })?.isTwin == true {
            return Tools.gate(Tools.has("qpdf"))
        }
        return !c.input.hasPrefix("fetched/") || Tools.required || FileManager.default.fileExists(atPath: Repo.corpus.appending(path: c.input).path)
    }

    /// Opens a case's input or output in PDFKit, unlocked.
    static func pdfKit(_ c: CorpusCase, data: Data) throws -> PDFDocument {
        guard let pk = PDFDocument(data: data) else { throw CorpusFailure("\(c.name): PDFKit can't open it") }
        if pk.isLocked, !pk.unlock(withPassword: c.pdfKitPassword ?? c.password ?? "") {
            throw CorpusFailure("\(c.name): PDFKit can't unlock it")
        }
        return pk
    }

    /// A fixed /NM, so an encrypted case and its plaintext twin add identical annotations.
    static func name(_ n: Int) -> String { String(format: "lectern-00000000-0000-4000-8000-%012d", n) }

    /// An encrypted file (EncryptedFixture), with the same edits on its plaintext twin.
    static func encrypted(_ fixture: String, password: String? = nil, pdfKitPassword: String? = nil,
                          saveability: Saveability = .inPlace,
                          _ changes: @escaping @Sendable (PDFSaveDocument, PDFDocument) throws -> [AnnotationChange]) -> [CorpusCase] {
        [CorpusCase(name: fixture, input: "\(fixture).pdf", saveability: saveability, password: password,
                    pdfKitPassword: pdfKitPassword, changes: changes),
         CorpusCase(name: "\(fixture).twin", input: "~\(fixture)", saveability: saveability, changes: changes)]
    }

    /// The usual encrypted-file edits: a highlight, a note on the last page, and an underline.
    static func standardEdits(_ label: String) -> @Sendable (PDFSaveDocument, PDFDocument) throws -> [AnnotationChange] {
        { _, pk in
            let last = pk.pageCount - 1
            let highlighted = try quads(pk, page: 0)
            // The hand-assembled file's text runs together into fewer lines than reportlab's.
            let underlined = try (try? lineQuad(pk, page: 0, line: 3, avoiding: highlighted)) ?? lineQuad(pk, page: 0, line: 0, avoiding: highlighted)
            return [.addMarkup(NewMarkup(kind: .highlight, pageIndex: 0, quads: highlighted, contents: "Highlight on \(label) ✓ ünïcode",
                                         author: author, name: name(1))),
                    .addNote(NewNote(pageIndex: last, origin: PDFPoint(x: 500, y: 700), contents: "Note on \(label)", author: author, name: name(2))),
                    .addMarkup(NewMarkup(kind: .underline, pageIndex: 0, quads: underlined,
                                         color: red, contents: nil, name: name(3)))]
        }
    }

    /// A second save on an encrypted output: edit, recolour and delete what the first one added.
    static let secondEdits: @Sendable (PDFSaveDocument, PDFDocument) throws -> [AnnotationChange] = { doc, pk in
        [.editContents(try find(doc, page: 0, subtype: "Highlight", lectern: true), "Edited on the second save"),
         .editColor(try find(doc, page: 0, subtype: "Underline", lectern: true), green),
         .delete(try find(doc, page: pk.pageCount - 1, subtype: "Text", lectern: true)),
         .addMarkup(NewMarkup(kind: .strikeOut, pageIndex: 0, quads: try quads(pk, page: 0, phrase: "lazy dog"), color: red,
                              contents: "Added on the second save", name: name(4)))]
    }

    static let allCases: [CorpusCase] = [
        CorpusCase(name: "classic-xref", input: "classic-xref.pdf") { _, pk in
            [try highlight(pk, page: 0, "Highlight on a classic xref file"), note(pk, page: 0, "Sticky note, page 1"),
             try highlight(pk, page: 1, "Second page highlight ✓ ünïcode"),
             .addMarkup(NewMarkup(kind: .underline, pageIndex: 1, quads: try quads(pk, page: 1, phrase: "quick brown fox"),
                                  color: red, contents: "Underline")),
             .addMarkup(NewMarkup(kind: .strikeOut, pageIndex: 1, quads: try quads(pk, page: 1, phrase: "original bytes"),
                                  color: red))]
        },
        CorpusCase(name: "classic-xref-no-ap", input: "classic-xref.pdf", appearanceStreams: false) { _, pk in
            [try highlight(pk, page: 0, "Highlight without /AP"), note(pk, page: 0, "Note without /AP")]
        },
        CorpusCase(name: "xref-stream-objstm", input: "xref-stream-objstm.pdf") { _, pk in
            // Page 1 has an indirect /Annots array (holding a Link); page 2 has none and lives in an object stream.
            [try highlight(pk, page: 0, "Highlight next to an indirect /Annots array"), note(pk, page: 1, "Note on page 2")]
        },
        CorpusCase(name: "incremental-existing", input: "incremental-existing.pdf") { doc, pk in
            [try highlight(pk, page: 0, "Highlight on top of an earlier update"),
             .editContents(try find(doc, page: 0, subtype: "Text"), "Edited by Lectern"),
             note(pk, page: 1, "Note on page 2")]
        },
        CorpusCase(name: "signed-approval", input: "signed-approval.pdf", saveability: .copyOnly([.signed])) { _, pk in
            [try highlight(pk, page: 0, "Highlight on a signed file"), note(pk, page: 1, "Note on a signed file")]
        },
        CorpusCase(name: "certified-docmdp", input: "certified-docmdp.pdf", saveability: .copyOnly([.certified, .signed])) { _, pk in
            [try highlight(pk, page: 0, "Highlight on a certified file"), note(pk, page: 1, "Note on a certified file")]
        },
        CorpusCase(name: "acroform-filled", input: "acroform-filled.pdf") { _, pk in
            [try highlight(pk, page: 0, "Highlight beside form fields"), note(pk, page: 0, "Note beside form fields")]
        },
        CorpusCase(name: "third-party-annots", input: "third-party-annots.pdf") { doc, pk in
            [try highlight(pk, page: 0, "Lectern highlight among MuPDF annotations"),
             .editContents(try find(doc, page: 0, subtype: "Square"), "Square edited by Lectern"),
             .editColor(try find(doc, page: 0, subtype: "Highlight"), green),
             .delete(try find(doc, page: 0, subtype: "Text"))]
        },
        CorpusCase(name: "mixed-page-sizes", input: "mixed-page-sizes.pdf") { _, pk in
            try (0..<5).map { try highlight(pk, page: $0, "Highlight on mixed page \($0 + 1)") }
                + [note(pk, page: 3, "Note on the rotated page")]
        },
        CorpusCase(name: "hybrid-xref", input: "hybrid-xref.pdf") { _, pk in
            [try highlight(pk, page: 0, "Highlight on a hybrid file"), note(pk, page: 1, "Note on a hybrid file")]
        },
        CorpusCase(name: "linearized-qpdf", input: "linearized-qpdf.pdf") { _, pk in
            [try highlight(pk, page: 2, "Highlight on a linearized file"), note(pk, page: 0, "Note on page 1"),
             .addMarkup(NewMarkup(kind: .strikeOut, pageIndex: 3, quads: try quads(pk, page: 3, phrase: "quick brown fox"),
                                  color: red))]
        },
        // Second saves: our own output as input, so the chain has two of our sections.
        CorpusCase(name: "classic-xref-second-save", input: "@classic-xref") { doc, pk in
            [.editContents(try find(doc, page: 0, subtype: "Highlight"), "Edited on the second save"),
             .editColor(try find(doc, page: 0, subtype: "Highlight"), green),
             .editColor(try find(doc, page: 1, subtype: "Underline"), green),
             .delete(try find(doc, page: 0, subtype: "Text")),
             try highlight(pk, page: 1, "Added on the second save", phrase: "lazy dog")]
        },
        CorpusCase(name: "xref-stream-second-save", input: "@xref-stream-objstm") { doc, pk in
            [.delete(try find(doc, page: 0, subtype: "Highlight")),
             try highlight(pk, page: 2, "Added on the second save", phrase: "quick brown fox")]
        },

        // Real-world files (Tests/Corpus/README.md lists sources and licences).
        realWorld("arxiv-2208.04284v5", phrase: "Rademacher complexity"),
        realWorld("arxiv-2310.12457v2", phrase: "unfolded GNNs"),
        realWorld("arxiv-2402.16746v1", phrase: "Rosseland approximation"),
        realWorld("arxiv-2502.20639v1", phrase: "heterogeneous models"),
        realWorld("arxiv-2503.00201v1", phrase: "Automated Market Makers"),
        realWorld("nasa-tm-20180002207", phrase: "dedicated"),
        realWorld("nasa-tm-2020-220520", phrase: "dedicated"),
        realWorld("irs-fw9", phrase: "social security number", saveability: .copyOnly([.readerExtended])),
        realWorld("irs-f1040", phrase: "adjusted gross income", saveability: .copyOnly([.readerExtended])),
        // M6 representative documents (spec §9.1): a long text-heavy book, a 3,270-page manual,
        // a scan with no text layer, and (fetched by scripts/corpus/bootstrap) an image-heavy report.
        // GovInfo signs and certifies its PDFs (a real DocMDP certification), so this one is copy-only.
        realWorld("gpo-style-manual-2016", phrase: "vegetable oil-based ink", saveability: .copyOnly([.certified, .signed])),
        realWorld("postgresql-17.11-US", phrase: "PostgreSQL Global Development Group"),
        CorpusCase(name: "annals-surgery-1886-anthrax-scan", input: "realworld/annals-surgery-1886-anthrax-scan.pdf") { _, _ in
            // No text layer, so no phrase to find: markup over fixed rectangles in the text block.
            let name = "annals-surgery-1886-anthrax-scan"
            return [.addMarkup(NewMarkup(kind: .highlight, pageIndex: 1, quads: [Quad(rect: PDFRect(x: 60, y: 330, width: 210, height: 12))],
                                         contents: "Highlight on \(name)", author: author)),
                    .addMarkup(NewMarkup(kind: .underline, pageIndex: 1, quads: [Quad(rect: PDFRect(x: 60, y: 250, width: 210, height: 12))],
                                         color: red, contents: "Underline on \(name)")),
                    .addNote(NewNote(pageIndex: 0, origin: PDFPoint(x: 280, y: 450), contents: "Note on \(name)", author: author))]
        },
        realWorld("nasa-earth-at-night", phrase: "brilliance of our planet", page: 9, folder: "fetched"),
        // A second save on a real-world output: edit and delete what the first save added.
        CorpusCase(name: "arxiv-2208.04284v5-second-save", input: "@arxiv-2208.04284v5") { doc, pk in
            [.editColor(try find(doc, page: 1, subtype: "Highlight", lectern: true), green),
             .editContents(try find(doc, page: 0, subtype: "Text", lectern: true), "Edited on the second save"),
             .delete(try find(doc, page: 1, subtype: "Underline", lectern: true)),
             try markup(.underline, pk, page: 2, line: 3, "Underline on the second save")]
        },

    ] + encryptedCases

    /// Encrypted files (M7). Each supported variant has a plaintext twin with the same edits.
    static let encryptedCases: [CorpusCase] =
        encrypted("encrypted-r2-rc4-40", password: "user-pass", standardEdits("R2 RC4-40"))
        + encrypted("encrypted-r3-rc4-annotated") { doc, pk in
            // Annotations from another app (MuPDF), edited through their decrypted descriptors.
            [.addMarkup(NewMarkup(kind: .highlight, pageIndex: 0, quads: try quads(pk, page: 0), contents: "Highlight among MuPDF annotations",
                                  author: author, name: name(1))),
             .editContents(try find(doc, page: 0, subtype: "Square"), "Square edited by Lectern"),
             .editColor(try find(doc, page: 0, subtype: "Highlight", lectern: false), green),
             .delete(try find(doc, page: 0, subtype: "Text"))]
        }
        // Page 1's /Annots is direct, holding an inline note, and the page has strings of its own
        // (/PieceInfo): the highlight rewrites the page, which must be encrypted again.
        + encrypted("encrypted-r3-rc4-56", password: "user-pass", standardEdits("R3 RC4-56"))
        + encrypted("encrypted-r4-rc4", password: "pässwörd", pdfKitPassword: "owner-pass", standardEdits("R4 RC4"))
        + encrypted("encrypted-r4-aes128-objstm", password: "user-pass", standardEdits("R4 AES-128"))
        + encrypted("encrypted-r4-cleartext-metadata", standardEdits("R4 cleartext metadata"))
        + encrypted("encrypted-r4-identity-strings") { doc, pk in
            try standardEdits("R4 identity strings")(doc, pk) + [.editContents(try find(doc, page: 0, subtype: "Text", lectern: false), "Edited in the clear")]
        }
        + encrypted("encrypted-aes256", password: "user-pass", standardEdits("R6"))
        // Its /P forbids annotating, so the app only saves it after the owner password (B6).
        + encrypted("encrypted-aes256-owner-only", password: "owner-pass", standardEdits("R6 with the owner password"))
        + encrypted("encrypted-r6-objstm-restricted", standardEdits("R6 restricted"))
        + encrypted("encrypted-r6-unicode", password: "Grüße-ключ", pdfKitPassword: "owner-pass", standardEdits("R6 unicode password"))
        + encrypted("encrypted-signed", saveability: .copyOnly([.signed]), standardEdits("an encrypted signed file"))
        + [
            CorpusCase(name: "encrypted-r4-aes128-objstm-second-save", input: "@encrypted-r4-aes128-objstm", password: "user-pass",
                       changes: secondEdits),
            CorpusCase(name: "encrypted-r4-aes128-objstm-second-save.twin", input: "@encrypted-r4-aes128-objstm.twin", changes: secondEdits),
            CorpusCase(name: "encrypted-aes256-second-save", input: "@encrypted-aes256", password: "user-pass", changes: secondEdits),
            CorpusCase(name: "encrypted-aes256-second-save.twin", input: "@encrypted-aes256.twin", changes: secondEdits),
            CorpusCase(name: "encrypted-r2-rc4-40-second-save", input: "@encrypted-r2-rc4-40", password: "user-pass", changes: secondEdits),
            CorpusCase(name: "encrypted-r2-rc4-40-second-save.twin", input: "@encrypted-r2-rc4-40.twin", changes: secondEdits),
            // Still refused.
            CorpusCase(name: "encrypted-r5", input: "encrypted-r5.pdf", saveability: .unsupported(.encrypted(.revision(version: 5, revision: 5))),
                       password: "user-pass") { _, _ in [] },
            CorpusCase(name: "encrypted-pubkey", input: "encrypted-pubkey.pdf",
                       saveability: .unsupported(.encrypted(.securityHandler("Adobe.PubSec")))) { _, _ in [] },
        ]

    /// Runs every case once, in order, and writes the outputs plus a manifest for scripts/corpus/verify.
    static let run: Result<[CorpusOutcome], CorpusFailure> = {
        do { return .success(try runAll()) } catch let e as CorpusFailure { return .failure(e) } catch {
            return .failure(CorpusFailure("\(error)"))
        }
    }()

    static func outcomes() throws -> [CorpusOutcome] { try run.get() }

    private static func runAll() throws -> [CorpusOutcome] {
        let fm = FileManager.default
        try? fm.removeItem(at: Repo.outputDirectory)
        try fm.createDirectory(at: Repo.outputDirectory, withIntermediateDirectories: true)
        var outcomes: [CorpusOutcome] = []
        var outputs: [String: URL] = [:]
        // One case at a time: a case that can't run (a missing input, a twin qpdf can't make)
        // becomes that case's failure, and the others still run.
        func runCase(_ c: CorpusCase) throws {
                let inputURL: URL
                if c.input.hasPrefix("@") {
                    guard let previous = outputs[String(c.input.dropFirst())] else { throw CorpusFailure("\(c.name): base output missing") }
                    inputURL = previous
                } else if c.input.hasPrefix("~") {
                    // The plaintext twin: qpdf's decryption of the encrypted case's input.
                    let base = String(c.input.dropFirst())
                    guard let encrypted = cases.first(where: { $0.name == base }) else { throw CorpusFailure("\(c.name): no case \(base)") }
                    inputURL = Repo.outputDirectory.appending(path: "\(base).twin-input.pdf")
                    try Qpdf.run(["--decrypt", Repo.corpus.appending(path: encrypted.input).path, inputURL.path], password: encrypted.password)
                } else {
                    inputURL = Repo.corpus.appending(path: c.input)
                }
                guard let original = try? Data(contentsOf: inputURL) else {
                    let hint = c.input.hasPrefix("fetched/") ? "; run scripts/corpus/bootstrap --fetch" : ""
                    outcomes.append(CorpusOutcome(testCase: c, inputURL: inputURL, outputURL: nil, result: nil, error: nil, changes: [],
                                                  removedInfo: [], editedInfo: [], problem: "input \(c.input) is missing\(hint)"))
                    return
                }
                var changes: [AnnotationChange] = []
                var outcome = CorpusOutcome(testCase: c, inputURL: inputURL, outputURL: nil, result: nil, error: nil,
                                            changes: [], removedInfo: [], editedInfo: [])
                var removedInfo: [AnnotationDescriptor] = []
                var editedInfo: [AnnotationDescriptor] = []
                if !c.isRefused {
                    let doc = try PDFSaveDocument(data: original, password: c.password)
                    let pk = try pdfKit(c, data: original)
                    changes = try c.changes(doc, pk)
                    let all = try doc.annotations()
                    // PDFKit reports a /Popup with its parent's Contents, so key popups that way.
                    func shown(_ info: AnnotationDescriptor) -> String {
                        let parent = all.first { $0.popup != nil && $0.popup == info.ref }
                        return Corpus.key(info.subtype, info.subtype == "Popup" ? parent?.contents : info.contents)
                    }
                    for change in changes {
                        switch change {
                        case .delete(let ref):
                            // The writer also drops the popup and replies; mirror that for expectations.
                            let target = all.filter { $0.ref == ref }
                            let replies = all.filter { $0.inReplyTo == ref }
                            let popups = all.filter { info in info.subtype == "Popup" && (target + replies).contains { $0.popup != nil && $0.popup == info.ref } }
                            removedInfo += target + replies + popups
                            outcome.pdfKitRemoved += (target + replies + popups).map { (page: $0.pageIndex, key: shown($0)) }
                        case .editContents(let ref, let text):
                            let target = all.filter { $0.ref == ref }
                            editedInfo += target
                            for info in target {
                                outcome.pdfKitRemoved.append((page: info.pageIndex, key: shown(info)))
                                outcome.pdfKitAdded.append((page: info.pageIndex, key: Corpus.key(info.subtype, text)))
                                if let popup = all.first(where: { info.popup != nil && $0.ref == info.popup }) {
                                    outcome.pdfKitRemoved.append((page: popup.pageIndex, key: shown(popup)))
                                    outcome.pdfKitAdded.append((page: popup.pageIndex, key: Corpus.key("Popup", text)))
                                }
                            }
                        case .editColor(let ref, _):
                            editedInfo += all.filter { $0.ref == ref }
                        case .addMarkup(let m):
                            outcome.pdfKitAdded.append((page: m.pageIndex, key: Corpus.key(m.kind.subtype, m.contents)))
                            if let q = m.quads.first {
                                outcome.probes.append((page: m.pageIndex, rect: q.bounds, kind: m.kind == .highlight ? .fill : .line))
                            }
                        case .addNote(let n):
                            outcome.pdfKitAdded.append((page: n.pageIndex, key: Corpus.key("Text", n.contents)))
                        }
                    }
                }
                outcome = CorpusOutcome(testCase: c, inputURL: inputURL, outputURL: nil, result: nil, error: nil, changes: changes,
                                        removedInfo: removedInfo, editedInfo: editedInfo, pdfKitRemoved: outcome.pdfKitRemoved,
                                        pdfKitAdded: outcome.pdfKitAdded, probes: outcome.probes)
                let writer = IncrementalWriter(options: .init(appearanceStreams: c.appearanceStreams))
                let saved: SaveResult
                do throws(PDFSaveError) {
                    if case .copyOnly = c.saveability {
                        saved = try writer.saveCopy(original: original, changes: changes, password: c.password)
                    } else {
                        saved = try writer.saveInPlace(original: original, changes: changes, password: c.password)
                    }
                    // The app's read-back check, with the same password.
                    try SavedFileCheck.verify(saved.data, original: original, against: saved, password: c.password)
                } catch {
                    outcomes.append(CorpusOutcome(testCase: c, inputURL: inputURL, outputURL: nil, result: nil, error: error,
                                                  changes: changes, removedInfo: removedInfo, editedInfo: editedInfo))
                    return
                }
                let out = Repo.outputDirectory.appending(path: "\(c.name).pdf")
                try saved.data.write(to: out)
                outputs[c.name] = out
                outcomes.append(CorpusOutcome(testCase: c, inputURL: inputURL, outputURL: out, result: saved, error: nil,
                                              changes: changes, removedInfo: removedInfo, editedInfo: editedInfo,
                                              pdfKitRemoved: outcome.pdfKitRemoved, pdfKitAdded: outcome.pdfKitAdded,
                                              probes: outcome.probes))
        }
        for c in cases {
            do {
                try runCase(c)
            } catch {
                outcomes.append(CorpusOutcome(testCase: c, inputURL: Repo.corpus.appending(path: c.input), outputURL: nil, result: nil,
                                              error: nil, changes: [], removedInfo: [], editedInfo: [], problem: "\(error)"))
            }
        }
        try writeManifest(outcomes)
        return outcomes
    }

    static func writeManifest(_ outcomes: [CorpusOutcome]) throws {
        func ref(_ r: ObjectRef) -> String { "\(r.number) \(r.generation)" }
        var cases: [[String: Any]] = []
        for o in outcomes where o.problem == nil {
            var entry: [String: Any] = ["name": o.testCase.name, "input": o.inputURL.path]
            entry["output"] = o.outputURL?.path ?? NSNull()
            if case .unsupported(.encrypted(let problem)) = o.testCase.saveability {
                entry["expectError"] = "\(PDFSaveError.encrypted(problem))"
            } else {
                entry["expectError"] = NSNull()
            }
            // The external tools' libraries take a password's bytes as given (pikepdf, poppler,
            // MuPDF), so a non-ASCII one reaches them as UTF-8, not the PDFDocEncoding an R4 file
            // needs: those files are opened with the (ASCII) owner password there, as in PDFKit.
            // EncryptionTests checks the non-ASCII user passwords against qpdf's own key.
            entry["password"] = o.testCase.pdfKitPassword ?? o.testCase.password ?? NSNull()
            if !o.testCase.isTwin, let twin = outcomes.first(where: { $0.testCase.twinOf == o.testCase.name }) {
                entry["twinOutput"] = twin.outputURL?.path ?? NSNull()
            }
            entry["twin"] = o.testCase.isTwin
            entry["error"] = o.error.map { "\($0)" } ?? NSNull()
            entry["appearanceStreams"] = o.testCase.appearanceStreams
            if let r = o.result {
                var added: [[String: Any]] = []
                var addIndex = 0
                for change in o.changes {
                    switch change {
                    case .addMarkup(let m):
                        added.append(["ref": ref(r.added[addIndex].ref), "subtype": m.kind.subtype,
                                      "contents": m.contents ?? "", "page": m.pageIndex])
                        addIndex += 1
                    case .addNote(let n):
                        added.append(["ref": ref(r.added[addIndex].ref), "subtype": "Text",
                                      "contents": n.contents ?? "", "page": n.pageIndex])
                        addIndex += 1
                    default: break
                    }
                }
                entry["added"] = added
                entry["edited"] = o.changes.compactMap { c -> [String: Any]? in
                    guard case .editContents(let r, let text) = c else { return nil }
                    return ["ref": ref(r), "contents": text ?? ""]
                }
                entry["removed"] = r.removedAnnotations.map(ref)
                entry["rewritten"] = r.rewrittenObjects.map(ref)
                entry["written"] = r.writtenObjects.map(ref)
                entry["xrefKind"] = r.xrefKind.rawValue
                entry["probes"] = o.probes.map {
                    ["page": $0.page, "rect": [$0.rect.x, $0.rect.y, $0.rect.maxX, $0.rect.maxY], "kind": $0.kind.rawValue]
                }
            }
            cases.append(entry)
        }
        let data = try JSONSerialization.data(withJSONObject: ["cases": cases], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: Repo.outputDirectory.appending(path: "manifest.json"))
    }
}

enum Qpdf {
    /// Runs qpdf; exit 0 and 3 (warnings) are success.
    /// The password goes through a file: Foundation's `Process` decomposes non-ASCII arguments, and
    /// qpdf would then see other bytes than the password's.
    static func run(_ arguments: [String], password: String? = nil) throws {
        guard let qpdf = Tools.path("qpdf") else { throw CorpusFailure("qpdf not installed") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: qpdf)
        var arguments = arguments
        if let password {
            let file = FileManager.default.temporaryDirectory.appending(path: "lectern-pw-\(UUID().uuidString)")
            try Data((password + "\n").utf8).write(to: file)
            arguments.insert("--password-file=\(file.path)", at: 0)
        }
        process.arguments = arguments
        // qpdf reads a non-ASCII password as UTF-8 only under a UTF-8 locale.
        process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "en_US.UTF-8"]) { $1 }
        let err = Pipe()
        process.standardError = err
        process.standardOutput = Pipe()
        try process.run()
        let message = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard [0, 3].contains(process.terminationStatus) else {
            throw CorpusFailure("qpdf \(arguments.joined(separator: " ")): exit \(process.terminationStatus) \(String(decoding: message, as: UTF8.self))")
        }
    }
}

struct CorpusFailure: Error, CustomStringConvertible, Sendable {
    let description: String
    init(_ d: String) { description = d }
}

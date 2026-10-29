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
    static let verifyScript = root.appending(path: "scripts/corpus/verify")
    static let venvPython = root.appending(path: ".venv/bin/python")
    static let pdfjs = root.appending(path: "scripts/corpus/node_modules/pdfjs-dist")

    static let outputDirectory: URL = {
        if let custom = ProcessInfo.processInfo.environment["LECTERN_CORPUS_OUT"] { return URL(fileURLWithPath: custom) }
        return FileManager.default.temporaryDirectory.appending(path: "lectern-m0a-corpus")
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
    /// A corpus file name, or "@<case>" to start from another case's output (a second save).
    let input: String
    var expectError: PDFSaveError?
    var appearanceStreams = true
    let changes: @Sendable (PDFSaveDocument, PDFDocument) throws -> [AnnotationChange]

    var testDescription: String { name }
}

/// The result of running one case, shared by all tests.
struct CorpusOutcome: Sendable {
    let testCase: CorpusCase
    let inputURL: URL
    let outputURL: URL?
    let result: SaveResult?
    let error: PDFSaveError?
    let changes: [AnnotationChange]
    /// (subtype, contents) of annotations the writer removed or edited, read before the save.
    let removedInfo: [AnnotationInfo]
    let editedInfo: [AnnotationInfo]
    /// Expected change to PDFKit's per-page list of "Type|Contents" keys.
    var pdfKitRemoved: [(page: Int, key: String)] = []
    var pdfKitAdded: [(page: Int, key: String)] = []
    let probes: [(page: Int, rect: PDFRect)]
}

enum Corpus {
    static let author = "Lectern Tester"

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

    static func highlight(_ doc: PDFDocument, page: Int, _ contents: String,
                          phrase: String = "Lectern test corpus") throws -> AnnotationChange {
        .addHighlight(NewHighlight(pageIndex: page, quads: try quads(doc, page: page, phrase: phrase), contents: contents, author: author))
    }

    static func note(_ doc: PDFDocument, page: Int, _ contents: String) -> AnnotationChange {
        let box = doc.page(at: page)!.bounds(for: .mediaBox)
        return .addNote(NewNote(pageIndex: page, origin: PDFPoint(x: box.maxX - 60, y: box.maxY - 60),
                                contents: contents, author: author))
    }

    static func find(_ doc: PDFSaveDocument, page: Int, subtype: String, contents: String? = nil) throws -> ObjectRef {
        let match = try doc.annotations(onPage: page).first { $0.subtype == subtype && (contents == nil || $0.contents == contents) }
        guard let match else { throw CorpusFailure("no \(subtype) annotation on page \(page)") }
        return match.ref
    }

    static let cases: [CorpusCase] = [
        CorpusCase(name: "classic-xref", input: "classic-xref.pdf") { _, pk in
            [try highlight(pk, page: 0, "Highlight on a classic xref file"), note(pk, page: 0, "Sticky note, page 1"),
             try highlight(pk, page: 1, "Second page highlight ✓ ünïcode")]
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
        CorpusCase(name: "signed-approval", input: "signed-approval.pdf") { _, pk in
            [try highlight(pk, page: 0, "Highlight on a signed file"), note(pk, page: 1, "Note on a signed file")]
        },
        CorpusCase(name: "acroform-filled", input: "acroform-filled.pdf") { _, pk in
            [try highlight(pk, page: 0, "Highlight beside form fields"), note(pk, page: 0, "Note beside form fields")]
        },
        CorpusCase(name: "third-party-annots", input: "third-party-annots.pdf") { doc, pk in
            [try highlight(pk, page: 0, "Lectern highlight among MuPDF annotations"),
             .editContents(try find(doc, page: 0, subtype: "Square"), "Square edited by Lectern"),
             .delete(try find(doc, page: 0, subtype: "Text"))]
        },
        CorpusCase(name: "mixed-page-sizes", input: "mixed-page-sizes.pdf") { _, pk in
            try (0..<5).map { try highlight(pk, page: $0, "Highlight on mixed page \($0 + 1)") }
                + [note(pk, page: 3, "Note on the rotated page")]
        },
        CorpusCase(name: "hybrid-xref", input: "hybrid-xref.pdf") { _, pk in
            [try highlight(pk, page: 0, "Highlight on a hybrid file"), note(pk, page: 1, "Note on a hybrid file")]
        },
        // Second saves: our own output as input, so the chain has two of our sections.
        CorpusCase(name: "classic-xref-second-save", input: "@classic-xref") { doc, pk in
            [.editContents(try find(doc, page: 0, subtype: "Highlight"), "Edited on the second save"),
             .delete(try find(doc, page: 0, subtype: "Text")),
             try highlight(pk, page: 1, "Added on the second save", phrase: "quick brown fox")]
        },
        CorpusCase(name: "xref-stream-second-save", input: "@xref-stream-objstm") { doc, pk in
            [.delete(try find(doc, page: 0, subtype: "Highlight")),
             try highlight(pk, page: 2, "Added on the second save", phrase: "quick brown fox")]
        },
        CorpusCase(name: "encrypted-aes256", input: "encrypted-aes256.pdf", expectError: .encrypted) { _, _ in
            [.addNote(NewNote(pageIndex: 0, origin: PDFPoint(x: 10, y: 10), contents: "never written"))]
        },
        CorpusCase(name: "encrypted-aes256-owner-only", input: "encrypted-aes256-owner-only.pdf", expectError: .encrypted) { _, _ in
            [.addNote(NewNote(pageIndex: 0, origin: PDFPoint(x: 10, y: 10), contents: "never written"))]
        },
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
        // Fixed date so outputs are stable between runs (except /NM, which is a fresh UUID).
        let date = Date(timeIntervalSince1970: 1_793_000_000)
        var outcomes: [CorpusOutcome] = []
        var outputs: [String: URL] = [:]
        for c in cases {
            let inputURL: URL
            if c.input.hasPrefix("@") {
                guard let previous = outputs[String(c.input.dropFirst())] else { throw CorpusFailure("\(c.name): base output missing") }
                inputURL = previous
            } else {
                inputURL = Repo.corpus.appending(path: c.input)
            }
            let original = try Data(contentsOf: inputURL)
            var changes: [AnnotationChange] = []
            var removedInfo: [AnnotationInfo] = []
            var editedInfo: [AnnotationInfo] = []
            var pdfKitRemoved: [(page: Int, key: String)] = []
            var pdfKitAdded: [(page: Int, key: String)] = []
            if c.expectError == nil {
                let doc = try PDFSaveDocument(data: original)
                guard let pk = PDFDocument(data: original) else { throw CorpusFailure("\(c.name): PDFKit can't open input") }
                changes = try c.changes(doc, pk)
                let all = try (0..<doc.pageCount).flatMap { try doc.annotations(onPage: $0) }
                // PDFKit reports a /Popup with its parent's Contents, so key popups that way.
                func shown(_ info: AnnotationInfo) -> String {
                    let parent = all.first { $0.popup == info.ref }
                    return Corpus.key(info.subtype, info.subtype == "Popup" ? parent?.contents : info.contents)
                }
                for change in changes {
                    switch change {
                    case .delete(let ref):
                        // The writer also drops the popup and replies; mirror that for expectations.
                        let target = all.filter { $0.ref == ref }
                        let replies = all.filter { $0.inReplyTo == ref }
                        let popups = all.filter { info in (target + replies).contains { $0.popup == info.ref } }
                        removedInfo += target + replies + popups
                        pdfKitRemoved += (target + replies + popups).map { (page: $0.pageIndex, key: shown($0)) }
                    case .editContents(let ref, let text):
                        let target = all.filter { $0.ref == ref }
                        editedInfo += target
                        for info in target {
                            pdfKitRemoved.append((page: info.pageIndex, key: shown(info)))
                            pdfKitAdded.append((page: info.pageIndex, key: Corpus.key(info.subtype, text)))
                            if let popup = all.first(where: { $0.ref == info.popup }) {
                                pdfKitRemoved.append((page: popup.pageIndex, key: shown(popup)))
                                pdfKitAdded.append((page: popup.pageIndex, key: Corpus.key("Popup", text)))
                            }
                        }
                    case .addHighlight(let h):
                        pdfKitAdded.append((page: h.pageIndex, key: Corpus.key("Highlight", h.contents)))
                    case .addNote(let n):
                        pdfKitAdded.append((page: n.pageIndex, key: Corpus.key("Text", n.contents)))
                    }
                }
            } else {
                // Files the writer must refuse can't be parsed to build changes; use a fixed one.
                changes = [.addNote(NewNote(pageIndex: 0, origin: PDFPoint(x: 10, y: 10), contents: "never written"))]
            }
            let writer = IncrementalWriter(options: .init(appearanceStreams: c.appearanceStreams, date: date))
            let saved: SaveResult
            do throws(PDFSaveError) {
                saved = try writer.save(original: original, changes: changes)
            } catch {
                outcomes.append(CorpusOutcome(testCase: c, inputURL: inputURL, outputURL: nil, result: nil, error: error,
                                              changes: changes, removedInfo: removedInfo, editedInfo: editedInfo, probes: []))
                continue
            }
            do {
                let result = saved
                let out = Repo.outputDirectory.appending(path: "\(c.name).pdf")
                try result.data.write(to: out)
                outputs[c.name] = out
                let probes = changes.compactMap { change -> (Int, PDFRect)? in
                    guard case .addHighlight(let h) = change, let q = h.quads.first else { return nil }
                    return (h.pageIndex, PDFRect(x: q.lowerLeft.x, y: q.lowerLeft.y,
                                                 width: q.upperRight.x - q.lowerLeft.x, height: q.upperRight.y - q.lowerLeft.y))
                }
                outcomes.append(CorpusOutcome(testCase: c, inputURL: inputURL, outputURL: out, result: result, error: nil,
                                              changes: changes, removedInfo: removedInfo, editedInfo: editedInfo,
                                              pdfKitRemoved: pdfKitRemoved, pdfKitAdded: pdfKitAdded,
                                              probes: probes.map { (page: $0.0, rect: $0.1) }))
            }
        }
        try writeManifest(outcomes)
        return outcomes
    }

    static func writeManifest(_ outcomes: [CorpusOutcome]) throws {
        func ref(_ r: ObjectRef) -> String { "\(r.number) \(r.generation)" }
        var cases: [[String: Any]] = []
        for o in outcomes {
            var entry: [String: Any] = ["name": o.testCase.name, "input": o.inputURL.path]
            entry["output"] = o.outputURL?.path ?? NSNull()
            entry["expectError"] = o.testCase.expectError.map { "\($0)" } ?? NSNull()
            entry["error"] = o.error.map { "\($0)" } ?? NSNull()
            entry["appearanceStreams"] = o.testCase.appearanceStreams
            if let r = o.result {
                var added: [[String: Any]] = []
                var addIndex = 0
                for change in o.changes {
                    switch change {
                    case .addHighlight(let h):
                        added.append(["ref": ref(r.addedAnnotations[addIndex]), "subtype": "Highlight",
                                      "contents": h.contents ?? "", "page": h.pageIndex])
                        addIndex += 1
                    case .addNote(let n):
                        added.append(["ref": ref(r.addedAnnotations[addIndex]), "subtype": "Text",
                                      "contents": n.contents, "page": n.pageIndex])
                        addIndex += 1
                    default: break
                    }
                }
                entry["added"] = added
                entry["edited"] = o.changes.compactMap { c -> [String: Any]? in
                    guard case .editContents(let r, let text) = c else { return nil }
                    return ["ref": ref(r), "contents": text]
                }
                entry["removed"] = r.removedAnnotations.map(ref)
                entry["rewritten"] = r.rewrittenObjects.map(ref)
                entry["written"] = r.writtenObjects.map(ref)
                entry["xrefKind"] = r.xrefKind.rawValue
                entry["probes"] = o.probes.map { ["page": $0.page, "rect": [$0.rect.x, $0.rect.y, $0.rect.maxX, $0.rect.maxY]] }
            }
            cases.append(entry)
        }
        let data = try JSONSerialization.data(withJSONObject: ["cases": cases], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: Repo.outputDirectory.appending(path: "manifest.json"))
    }
}

struct CorpusFailure: Error, CustomStringConvertible, Sendable {
    let description: String
    init(_ d: String) { description = d }
}

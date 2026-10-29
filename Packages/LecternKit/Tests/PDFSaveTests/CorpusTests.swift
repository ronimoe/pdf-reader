import Foundation
import PDFKit
import Testing
@testable import PDFSave

/// Pass criteria from architecture §3.2, run over every file in Tests/Corpus/public.
/// Criteria 1, 3 and 7 are checked here in Swift; 2, 4, 5 and 6 are checked by
/// scripts/corpus/verify, which each external test below calls for one criterion.
@Suite struct CorpusTests {
    static let writable = Corpus.cases.filter { !$0.isRefused }
    static let refused = Corpus.cases.filter { $0.isRefused }

    func outcome(_ c: CorpusCase) throws -> CorpusOutcome {
        let all = try Corpus.outcomes()
        let o = try #require(all.first { $0.testCase.name == c.name })
        if let problem = o.problem { throw CorpusFailure("\(c.name): \(problem)") }
        return o
    }

    // 1. Original bytes intact.
    @Test(arguments: writable) func originalBytesArePrefix(_ c: CorpusCase) throws {
        let o = try outcome(c)
        let result = try #require(o.result, "writer failed: \(String(describing: o.error))")
        let original = try Data(contentsOf: o.inputURL)
        #expect(result.originalLength == original.count)
        #expect(result.data.count > original.count)
        #expect(result.data.prefix(original.count) == original)
    }

    // 3. Annotations round-trip in PDFKit: count, subtype and Contents per page.
    @Test(arguments: writable) func pdfKitShowsAnnotations(_ c: CorpusCase) throws {
        let o = try outcome(c)
        let result = try #require(o.result, "writer failed: \(String(describing: o.error))")
        let before = try Corpus.pdfKit(c, data: try Data(contentsOf: o.inputURL))
        let after = try Corpus.pdfKit(c, data: result.data)
        #expect(after.pageCount == before.pageCount)

        for page in 0..<before.pageCount {
            var expected = before.page(at: page)!.annotations.map { Corpus.key($0.type ?? "?", $0.contents) }
            for removed in o.pdfKitRemoved where removed.page == page {
                let i = try #require(expected.firstIndex(of: removed.key), "\(removed.key) not in the original")
                expected.remove(at: i)
            }
            expected += o.pdfKitAdded.filter { $0.page == page }.map(\.key)
            let actual = after.page(at: page)!.annotations.map { Corpus.key($0.type ?? "?", $0.contents) }
            #expect(actual.sorted() == expected.sorted(), "page \(page + 1)")
            #expect(actual.count == expected.count, "page \(page + 1) annotation count")
        }
    }

    /// Pixel statistics inside `rect` (PDF user space) after PDFKit draws the page at 72 dpi:
    /// the mean blue channel (2 px inset), and the number of strongly tinted pixels (red minus
    /// blue at least 50), which a thin red or yellow line raises even when antialiased over two pixel rows but black text doesn't.
    static func pixels(_ page: PDFPage, in rect: PDFRect) throws -> (meanBlue: Double, tinted: Int) {
        let box = page.bounds(for: .mediaBox)
        let width = Int(box.width.rounded()), height = Int(box.height.rounded())
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        page.draw(with: .mediaBox, to: ctx)
        let data = try #require(ctx.data).assumingMemoryBound(to: UInt8.self)
        func px(_ x: Int, _ y: Int) -> (r: Int, b: Int) {
            let row = height - 1 - y  // bitmap row 0 is the top of the page
            let i = row * width * 4 + x * 4
            return (Int(data[i]), Int(data[i + 2]))
        }
        var sum = 0.0, count = 0.0
        let x0 = Int(rect.x - box.minX) + 2, x1 = Int(rect.maxX - box.minX) - 2
        let y0 = Int(rect.y - box.minY) + 2, y1 = Int(rect.maxY - box.minY) - 2
        for y in y0..<max(y0 + 1, y1) {
            for x in x0..<max(x0 + 1, x1) { sum += Double(px(x, y).b); count += 1 }
        }
        var tinted = 0
        for y in max(0, y0 - 2)..<min(height, max(y0 - 1, y1 + 2)) {
            for x in max(0, x0 - 2)..<min(width, max(x0 - 1, x1 + 2)) where px(x, y).r - px(x, y).b >= 50 { tinted += 1 }
        }
        return (sum / count, tinted)
    }

    // 6 (Apple). PDFKit, the engine behind Preview, draws each new highlight, underline and strike-out.
    @Test(arguments: writable) func pdfKitDrawsMarkup(_ c: CorpusCase) throws {
        let o = try outcome(c)
        let result = try #require(o.result)
        let before = try Corpus.pdfKit(c, data: try Data(contentsOf: o.inputURL))
        let after = try Corpus.pdfKit(c, data: result.data)
        for probe in o.probes {
            let pageBefore = try #require(before.page(at: probe.page))
            let pageAfter = try #require(after.page(at: probe.page))
            guard pageAfter.rotation == 0 else { continue }  // pixel mapping assumes an unrotated page
            let b = try Self.pixels(pageBefore, in: probe.rect)
            let a = try Self.pixels(pageAfter, in: probe.rect)
            let drawn: Bool
            let detail: String
            switch probe.kind {
            case .fill:
                drawn = b.meanBlue - a.meanBlue >= 40
                detail = "blue \(Int(b.meanBlue)) -> \(Int(a.meanBlue))"
            case .line:
                drawn = a.tinted - b.tinted >= max(5, Int(probe.rect.width * 0.3))
                detail = "tinted px \(b.tinted) -> \(a.tinted)"
            }
            if c.appearanceStreams {
                #expect(drawn, "page \(probe.page + 1) \(probe.kind): \(detail)")
            } else {
                // Measurement only: does PDFKit draw markup that has no /AP?
                print("PDFKit, \(probe.kind) without /AP on page \(probe.page + 1): \(drawn ? "drawn" : "NOT drawn") (\(detail))")
            }
        }
    }

    // 7. Encryption Lectern doesn't write (R5, the public-key handler) can't be saved at all, in
    // place or as a copy, even with the password.
    @Test(arguments: refused) func unsupportedEncryptionIsRefused(_ c: CorpusCase) throws {
        let o = try outcome(c)
        guard case .unsupported(.encrypted(let problem)) = c.saveability else { Issue.record("not an encryption case"); return }
        #expect(o.result == nil)
        #expect(o.error == .encrypted(problem))
        let data = try Data(contentsOf: o.inputURL)
        #expect(throws: PDFSaveError.encrypted(problem)) {
            try IncrementalWriter().saveCopy(original: data, changes: [.testNote], password: c.password)
        }
    }

    // 7. Supported encryption: the output is encrypted with the original's key, keeps /Encrypt
    // and /ID exactly, and re-reads only with the password.
    @Test(arguments: writable.filter { $0.password != nil || $0.input.contains("encrypted") && !$0.isTwin })
    func encryptedOutputsKeepTheirEncryption(_ c: CorpusCase) throws {
        let o = try outcome(c)
        let result = try #require(o.result, "writer failed: \(String(describing: o.error))")
        let original = try Data(contentsOf: o.inputURL)
        let before = try PDFSaveDocument(data: original, password: c.password)
        let after = try PDFSaveDocument(data: result.data, password: c.password)
        #expect(before.isEncrypted && after.isEncrypted && result.isEncrypted)
        #expect(after.fileEncryptionKey == before.fileEncryptionKey)
        #expect(after.sections[0].trailer["Encrypt"] == before.sections[0].trailer["Encrypt"])
        #expect(after.sections[0].trailer["ID"] == before.trailer["ID"])
        if c.password != nil, !(c.password == "owner-pass") {
            #expect(throws: PDFSaveError.encrypted(.passwordNotAuthenticated)) { try PDFSaveDocument(data: result.data) }
        }
        // Nothing the update wrote is in the clear: no annotation text, name or appearance operator.
        let update = result.data.suffix(from: original.count)
        for change in o.changes {
            for text in [change.addedContents, change.addedName].compactMap({ $0 }) where !text.isEmpty {
                #expect(update.range(of: Data(text.utf8)) == nil, "\(text) is in the clear")
            }
        }
        if !(before.security?.streams == .identity) {
            #expect(update.range(of: Data("LecternHL gs".utf8)) == nil && update.range(of: Data(" re B".utf8)) == nil)
        }
    }

    // The strong oracle: the same edits on the plaintext twin and on the encrypted file give the
    // same annotations once qpdf decrypts the output (scripts/corpus/verify --check oracle).
    @Test(.enabled(if: Tools.gate(Tools.objectsCheck), "qpdf or repo .venv with pikepdf missing (scripts/corpus/bootstrap)"))
    func encryptedOutputsMatchTheirPlaintextTwins() throws {
        let encrypted = Corpus.cases.filter { c in Corpus.cases.contains { $0.twinOf == c.name } }.map(\.name)
        #expect(encrypted.count >= 14)
        try runVerify("oracle", available: Tools.objectsCheck, mustApply: Set(encrypted))
    }

    // Saveability: every input is classified as expected, and the writer's in-place guard agrees.
    @Test(arguments: Corpus.cases) func saveabilityIsAsExpected(_ c: CorpusCase) throws {
        let o = try outcome(c)
        let data = try Data(contentsOf: o.inputURL)
        #expect(Saveability.evaluate(data, password: c.password) == c.saveability)
        switch c.saveability {
        case .inPlace:
            #expect(Saveability.evaluate(data, readOnlyLocation: true, password: c.password) == .copyOnly([.readOnlyLocation]))
        case .copyOnly(let reasons):
            #expect(throws: PDFSaveError.copyOnly(reasons)) {
                try IncrementalWriter().saveInPlace(original: data, changes: [.testNote], password: c.password)
            }
            #expect(Saveability.evaluate(data, readOnlyLocation: true, password: c.password) == .copyOnly(reasons + [.readOnlyLocation]))
        case .unsupported:
            #expect(Saveability.evaluate(data, readOnlyLocation: true, password: c.password) == c.saveability)
        }
    }

    @Test func outputsOnlyRewriteWhatTheyMust() throws {
        for o in try Corpus.outcomes() where o.problem == nil {
            guard let r = o.result else { continue }
            let doc = try PDFSaveDocument(data: try Data(contentsOf: o.inputURL), password: o.testCase.password)
            let pages = Set(doc.pageRefs.map(\.number))
            for ref in r.rewrittenObjects {
                let object = try doc.object(ref)
                let isAnnotsArray = object.arrayValue != nil
                let isPage = pages.contains(ref.number)
                let isEditedAnnot = o.editedInfo.contains { $0.ref?.number == ref.number }
                #expect(isAnnotsArray || isPage || isEditedAnnot, "\(o.testCase.name): unexpected rewrite of \(ref)")
            }
        }
    }

    // MARK: External tools (scripts/corpus/verify)

    struct VerifyReport: Decodable { let results: [String: [String: String]] }

    func runVerify(_ check: String, available: Bool, mustApply: Set<String> = []) throws {
        guard available else {
            Issue.record("LECTERN_REQUIRE_TOOLS=1 but the tools for '\(check)' are missing (scripts/corpus/bootstrap)")
            return
        }
        _ = try Corpus.outcomes()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [Repo.verifyScript.path, "--manifest",
                             Repo.outputDirectory.appending(path: "manifest.json").path, "--check", check, "--json"]
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let report = try #require(try? JSONDecoder().decode(VerifyReport.self, from: out),
                                  "verify produced no report (exit \(process.terminationStatus)): \(String(decoding: err, as: UTF8.self))")
        #expect(!report.results.isEmpty)
        for name in mustApply { #expect(report.results[name] != nil, "\(name) missing from the verify report") }
        for (name, checks) in report.results.sorted(by: { $0.key < $1.key }) {
            for (criterion, status) in checks {
                if status.hasPrefix("skip") {
                    // The tool gate above said it was available, so a skip here is a failure, not silence.
                    Issue.record("\(name) \(criterion): \(status)")
                } else {
                    // "info" is a measurement (rendering of the no-/AP variant), not a criterion.
                    #expect(status.hasPrefix("pass") || status.hasPrefix("n/a") || status.hasPrefix("info"),
                            "\(name) \(criterion): \(status)")
                    if mustApply.contains(name) {
                        #expect(status.hasPrefix("pass"), "\(name) \(criterion) must be checked, got: \(status)")
                    }
                }
            }
        }
    }

    // Each external check is gated on its tools. A missing tool shows up as a skipped test with
    // the reason; with LECTERN_REQUIRE_TOOLS=1 (scripts/test.sh) the test runs and fails instead.

    // 2. Independent structural check.
    @Test(.enabled(if: Tools.gate(Tools.qpdfCheck), "qpdf or python3 not installed"))
    func qpdfCheckPasses() throws { try runVerify("qpdf", available: Tools.qpdfCheck) }

    // 2b. Every object of the original is unchanged in the new revision except the ones we rewrote.
    @Test(.enabled(if: Tools.gate(Tools.objectsCheck), "qpdf or repo .venv with pikepdf missing (scripts/corpus/bootstrap)"))
    func untouchedObjectsUnchanged() throws { try runVerify("objects", available: Tools.objectsCheck) }

    // 4. Form field values byte-identical (A5). The form and the signed file must actually be checked.
    @Test(.enabled(if: Tools.gate(Tools.venv), "repo .venv with pikepdf missing (scripts/corpus/bootstrap)"))
    func formFieldsUnchanged() throws {
        try runVerify("fields", available: Tools.venv,
                      mustApply: ["acroform-filled", "signed-approval", "certified-docmdp", "irs-fw9", "irs-f1040"])
    }

    // 5. Signature intact; "n/a" is not acceptable for the signed and certified files.
    @Test(.enabled(if: Tools.gate(Tools.venv), "repo .venv with pyHanko missing (scripts/corpus/bootstrap)"))
    func signatureStillIntact() throws {
        try runVerify("signature", available: Tools.venv, mustApply: ["signed-approval", "certified-docmdp", "encrypted-signed"])
    }

    // 6. Other readers: MuPDF, Poppler and pdf.js.
    @Test(.enabled(if: Tools.gate(Tools.mupdfCheck), "mutool or .venv missing"))
    func mupdfShowsAndDrawsAnnotations() throws { try runVerify("mupdf", available: Tools.mupdfCheck) }

    @Test(.enabled(if: Tools.gate(Tools.popplerCheck), "pdftoppm (poppler) or .venv missing"))
    func popplerRendersHighlights() throws { try runVerify("poppler", available: Tools.popplerCheck) }

    @Test(.enabled(if: Tools.gate(Tools.pdfjs), "node, pdfjs-dist, @napi-rs/canvas or .venv missing (scripts/corpus/bootstrap)"))
    func pdfjsShowsAnnotations() throws { try runVerify("pdfjs", available: Tools.pdfjs) }
}

import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import PDFSave

/// The test PDF regression suite (decision A6, architecture §9): every file in the collection must
/// open, render page 1, give text where it has a text layer, and close cleanly; and the writer
/// must have a case for every file (CorpusTests runs it, and refuses the encrypted ones).
///
/// The list below is checked against the folder in both directions, so a file added without an
/// entry fails here instead of being skipped.
@Suite struct RegressionSuiteTests {
    struct Entry: Sendable, CustomTestStringConvertible {
        /// Path under Tests/Corpus/public.
        let path: String
        var password: String?
        /// False for scans without a text layer: no page may give text.
        var hasText = true
        /// False for the public-key file, whose recipient key was thrown away: PDFKit opens it,
        /// but nothing can decrypt its pages, so it must give no text and isn't checked for ink.
        var decryptable = true
        var testDescription: String { path }
    }

    static let entries: [Entry] = [
        Entry(path: "classic-xref.pdf"),
        Entry(path: "xref-stream-objstm.pdf"),
        Entry(path: "incremental-existing.pdf"),
        Entry(path: "signed-approval.pdf"),
        Entry(path: "certified-docmdp.pdf"),
        Entry(path: "acroform-filled.pdf"),
        Entry(path: "third-party-annots.pdf"),
        Entry(path: "mixed-page-sizes.pdf"),
        Entry(path: "hybrid-xref.pdf"),
        Entry(path: "linearized-qpdf.pdf"),
        Entry(path: "encrypted-aes256.pdf", password: "user-pass"),
        Entry(path: "encrypted-aes256-owner-only.pdf"),
        Entry(path: "encrypted-r2-rc4-40.pdf", password: "user-pass"),
        Entry(path: "encrypted-r3-rc4-annotated.pdf"),
        Entry(path: "encrypted-r3-rc4-56.pdf", password: "user-pass"),
        // PDFKit can't unlock a non-ASCII password (EncryptionTests), so these open with the owner's.
        Entry(path: "encrypted-r4-rc4.pdf", password: "owner-pass"),
        Entry(path: "encrypted-r4-aes128-objstm.pdf", password: "user-pass"),
        Entry(path: "encrypted-r4-cleartext-metadata.pdf"),
        Entry(path: "encrypted-r4-identity-strings.pdf"),
        Entry(path: "encrypted-r6-objstm-restricted.pdf"),
        Entry(path: "encrypted-r6-unicode.pdf", password: "owner-pass"),
        Entry(path: "encrypted-signed.pdf"),
        Entry(path: "encrypted-r5.pdf", password: "user-pass"),
        Entry(path: "encrypted-pubkey.pdf", hasText: false, decryptable: false),
        Entry(path: "realworld/arxiv-2208.04284v5.pdf"),
        Entry(path: "realworld/arxiv-2310.12457v2.pdf"),
        Entry(path: "realworld/arxiv-2402.16746v1.pdf"),
        Entry(path: "realworld/arxiv-2502.20639v1.pdf"),
        Entry(path: "realworld/arxiv-2503.00201v1.pdf"),
        Entry(path: "realworld/nasa-tm-20180002207.pdf"),
        Entry(path: "realworld/nasa-tm-2020-220520.pdf"),
        Entry(path: "realworld/irs-fw9.pdf"),
        Entry(path: "realworld/irs-f1040.pdf"),
        Entry(path: "realworld/gpo-style-manual-2016.pdf"),
        Entry(path: "realworld/postgresql-17.11-US.pdf"),
        Entry(path: "realworld/annals-surgery-1886-anthrax-scan.pdf", hasText: false),
        Entry(path: "fetched/nasa-earth-at-night.pdf"),
    ]

    /// Entries whose file is here. Fetched files are required when tools are (scripts/test.sh).
    static let present: [Entry] = entries.filter { entry in
        !entry.path.hasPrefix("fetched/") || Tools.required || FileManager.default.fileExists(atPath: Repo.corpus.appending(path: entry.path).path)
    }

    /// Every PDF under Tests/Corpus/public, as paths relative to it.
    static func pdfsOnDisk() throws -> Set<String> {
        let base = Repo.corpus.standardizedFileURL.path + "/"
        guard let walker = FileManager.default.enumerator(at: Repo.corpus, includingPropertiesForKeys: nil) else {
            throw CorpusFailure("can't list \(Repo.corpus.path)")
        }
        var found: Set<String> = []
        for case let url as URL in walker where url.pathExtension.lowercased() == "pdf" {
            found.insert(String(url.standardizedFileURL.path.dropFirst(base.count)))
        }
        return found
    }

    @Test func everyFileHasAnEntryAndEveryEntryAFile() throws {
        let onDisk = try Self.pdfsOnDisk()
        let listed = Set(Self.entries.map(\.path))
        #expect(onDisk.subtracting(listed).isEmpty, "PDFs with no regression entry: \(onDisk.subtracting(listed).sorted())")
        let missing = Set(Self.present.map(\.path)).subtracting(onDisk)
        #expect(missing.isEmpty, "listed PDFs missing (fetched ones come from scripts/corpus/bootstrap --fetch): \(missing.sorted())")
    }

    @Test func theWriterHasACaseForEveryFile() {
        let inputs = Set(Corpus.cases.map(\.input))
        let uncovered = Self.present.map(\.path).filter { !inputs.contains($0) }
        #expect(uncovered.isEmpty, "files the writer is never run on: \(uncovered)")
    }

    @Test(arguments: present) func opensRendersGivesTextAndCloses(_ entry: Entry) throws {
        let url = Repo.corpus.appending(path: entry.path)
        weak var released: PDFDocument?
        try autoreleasepool {
            let document = try #require(PDFDocument(url: url), "PDFKit can't open \(entry.path)")
            if document.isLocked {
                let password = try #require(entry.password, "\(entry.path) is locked and has no password listed")
                #expect(document.unlock(withPassword: password))
            }
            #expect(document.pageCount > 0)
            let page = try #require(document.page(at: 0))
            if entry.decryptable {
                #expect(try Self.inkFraction(Self.render(page)) > 0.001, "page 1 of \(entry.path) rendered blank")
            }

            // Text: the first pages that have some (front matter can be all images), or none at all.
            if entry.hasText {
                let pages = min(document.pageCount, 12)
                let characters = (0..<pages).reduce(0) { sum, index in
                    sum + (document.page(at: index)?.string ?? "").filter { !$0.isWhitespace }.count
                }
                #expect(characters > 20, "\(entry.path): no text in the first \(pages) pages")
            } else {
                for index in 0..<document.pageCount {
                    let text = (document.page(at: index)?.string ?? "").filter { !$0.isWhitespace }
                    #expect(text.isEmpty, "\(entry.path) page \(index + 1) gave text: \(text.prefix(40))")
                }
            }
            released = document
        }
        // Nothing keeps the document alive once the reader lets go of it.
        #expect(released == nil, "\(entry.path) wasn't released")
    }

    /// Page 1 at about 400 pt wide, into an RGBA bitmap on white.
    static func render(_ page: PDFPage) throws -> CGImage {
        let box = page.bounds(for: .mediaBox)
        let rotated = page.rotation % 180 != 0
        let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
        let scale = 400 / max(size.width, 1)
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CorpusFailure("no context") }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        guard let image = context.makeImage() else { throw CorpusFailure("no image") }
        return image
    }

    /// The share of pixels that aren't near-white.
    static func inkFraction(_ image: CGImage) throws -> Double {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { throw CorpusFailure("no pixels") }
        let perRow = image.bytesPerRow, bpp = image.bitsPerPixel / 8
        var ink = 0
        for y in 0..<image.height {
            for x in 0..<image.width {
                let p = bytes + y * perRow + x * bpp
                if Int(p[0]) + Int(p[1]) + Int(p[2]) < 720 { ink += 1 }
            }
        }
        return Double(ink) / Double(image.width * image.height)
    }
}

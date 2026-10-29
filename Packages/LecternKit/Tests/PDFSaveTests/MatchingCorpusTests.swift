import Foundation
import PDFKit
import Testing
@testable import PDFSave

/// The matcher against PDFKit on every corpus file, before and after the save: what the app
/// (M4b) will do to map each `PDFAnnotation` to a file object.
@Suite struct MatchingCorpusTests {
    /// What the app will send: one query per PDFKit annotation.
    static func queries(_ doc: PDFDocument) -> [AnnotationQuery] {
        (0..<doc.pageCount).flatMap { index in
            doc.page(at: index)!.annotations.map { a in
                AnnotationQuery(pageIndex: index, subtype: a.type ?? "", rect: PDFRect(cgRect: a.bounds),
                                contentsAtOpen: a.contents, name: a.value(forAnnotationKey: .name) as? String)
            }
        }
    }

    struct Tally: CustomStringConvertible {
        var byMethod: [AnnotationMatch.Method: Int] = [:]
        var ambiguous = 0, notFound = 0, unaddressable = 0
        var maxDeviation = 0.0
        var description: String {
            "name \(byMethod[.name] ?? 0), name+geometry \(byMethod[.nameAndGeometry] ?? 0), geometry \(byMethod[.geometry] ?? 0), "
                + "geometry+contents \(byMethod[.geometryAndContents] ?? 0), ambiguous \(ambiguous), not found \(notFound), "
                + "unaddressable \(unaddressable), max /Rect deviation \(maxDeviation)"
        }
    }

    /// Matches every PDFKit annotation in `data` and checks each match is plausible.
    static func run(_ data: Data, label: String, case c: CorpusCase) throws -> (Tally, [AnnotationQuery], [AnnotationMatch], [AnnotationDescriptor]) {
        // An encrypted file: PDFKit's annotations against the decrypted descriptors.
        let pk = try Corpus.pdfKit(c, data: data)
        let descriptors = try PDFSaveDocument(data: data, password: c.password).annotations()
        let qs = queries(pk)
        let results = AnnotationMatcher().match(qs, in: descriptors)
        // Indexed, so the checks stay linear on the 3,270-page manual's 18,553 links.
        let byPage = Dictionary(grouping: descriptors, by: \.pageIndex)
        var byRef: [ObjectRef: AnnotationDescriptor] = [:]
        for d in descriptors { if let ref = d.ref, byRef[ref] == nil { byRef[ref] = d } }
        // The independent answer: PDFKit lists a page's annotations in /Annots order, so the n-th
        // PDFKit annotation on a page is the n-th descriptor on that page.
        var expected: [ObjectRef?] = []
        for page in 0..<pk.pageCount {
            let onPage = byPage[page] ?? []
            let count = pk.page(at: page)!.annotations.count
            try #require(onPage.count == count, "\(label) page \(page + 1): PDFKit lists \(count), /Annots has \(onPage.count)")
            expected += onPage.map(\.ref)
        }
        var tally = Tally()
        for (i, (q, r)) in zip(qs, results).enumerated() {
            switch r {
            case .matched(let ref, let method):
                tally.byMethod[method, default: 0] += 1
                let d = try #require(byRef[ref])
                #expect(ref == expected[i], "\(label): \(q) matched \(ref), but it is \(String(describing: expected[i])) in /Annots order")
                #expect(d.pageIndex == q.pageIndex && d.subtype == q.subtype, "\(label): \(q) matched \(d)")
                // How far PDFKit's bounds are from /Rect, to justify the tolerance (notes excepted).
                if q.subtype != "Text", let r = d.rect {
                    let dev = [abs(r.x - q.rect.x), abs(r.y - q.rect.y), abs(r.maxX - q.rect.maxX), abs(r.maxY - q.rect.maxY)].max()!
                    tally.maxDeviation = max(tally.maxDeviation, dev)
                }
            case .ambiguous(let refs):
                tally.ambiguous += 1
                // Only a real tie may be ambiguous: every candidate fits the query's page, subtype and rect.
                let candidates = refs.compactMap { byRef[$0] }
                #expect(candidates.count >= 1 && candidates.allSatisfy { d in
                    d.pageIndex == q.pageIndex && d.subtype == q.subtype
                        && (d.rect.map { $0.isClose(to: q.rect, tolerance: AnnotationMatcher().tolerance) } ?? false)
                }, "\(label): ambiguous \(q) among \(candidates)")
                print("matcher \(label): ambiguous \(q.subtype) p\(q.pageIndex + 1) \(q.rect) among \(refs) "
                      + "contents \(candidates.map { $0.contents ?? "-" })")
            case .notFound:
                tally.notFound += 1
                Issue.record("\(label): no match for \(q)")
            case .unaddressable: tally.unaddressable += 1
            }
        }
        return (tally, qs, results, descriptors)
    }

    @Test(arguments: CorpusTests.writable) func everyPDFKitAnnotationMatches(_ c: CorpusCase) throws {
        let o = try #require(try Corpus.outcomes().first { $0.testCase.name == c.name })
        if let problem = o.problem { throw CorpusFailure("\(c.name): \(problem)") }
        let result = try #require(o.result)
        let (before, _, _, _) = try Self.run(try Data(contentsOf: o.inputURL), label: "\(c.name) input", case: c)
        let (after, qs, results, _) = try Self.run(result.data, label: "\(c.name) output", case: c)
        print("matcher \(c.name): input [\(before)] output [\(after)]")

        // Our new annotations carry /NM; PDFKit reports it, so they match by name, to the object written.
        for added in result.added {
            let i = try #require(qs.firstIndex { $0.name == added.name }, "\(c.name): PDFKit doesn't show \(added.name)")
            #expect(results[i] == .matched(added.ref, .name), "\(c.name): \(added.name)")
        }
    }
}

extension PDFRect {
    init(cgRect r: CGRect) { self.init(x: r.minX, y: r.minY, width: r.width, height: r.height) }
}

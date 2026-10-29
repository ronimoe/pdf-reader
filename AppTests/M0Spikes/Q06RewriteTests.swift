import AppKit
import PDFKit
import Testing

extension M0bSpikes {
    /// Q6: dataRepresentation() rewrites the whole file. What does it drop
    /// or change on a file that already has an incremental update?
    @Suite struct Q6Rewrite {
        @Test func fixtureHasTwoRevisions() throws {
            let (base, updated) = SpikeFixtures.incremental()
            #expect(updated.starts(with: base))
            #expect(PDFBytes.count("%%EOF", in: updated) == 2)
            #expect(PDFBytes.containsName("/Prev", in: updated))
            let document = try #require(PDFDocument(data: updated))
            #expect(document.page(at: 0)?.string?.contains("Revision two text") == true)
            #expect(document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Updated Title")
        }

        @Test func unchangedDocumentIsStillRewritten() throws {
            let original = try #require(TestPDF.make(pageCount: 2))
            let rewritten = try #require(PDFDocument(data: original)?.dataRepresentation())
            #expect(rewritten != original)
            #expect(!rewritten.starts(with: original.prefix(original.count - 1)))
        }

        @Test func rewriteOfIncrementallyUpdatedFile() throws {
            let (_, updated) = SpikeFixtures.incremental()
            let document = try #require(PDFDocument(data: updated))
            let out = try #require(document.dataRepresentation())
            SpikeArtifacts.save(updated, as: "q6-incremental-original.pdf")
            SpikeArtifacts.save(out, as: "q6-incremental-rewritten.pdf")

            let header = String(decoding: out.prefix(8), as: UTF8.self)
            let reloaded = try #require(PDFDocument(data: out))
            let text = reloaded.page(at: 0)?.string ?? ""
            let attributes = reloaded.documentAttributes ?? [:]
            let observations: [String: Bool] = [
                "original is prefix": out.starts(with: updated),
                "single %%EOF": PDFBytes.count("%%EOF", in: out) == 1,
                "/Prev kept": PDFBytes.containsName("/Prev", in: out),
                "comment kept": PDFBytes.contains("lectern-comment-marker", in: out),
                "orphan object kept": PDFBytes.contains("orphan-object-marker", in: out),
                "custom catalog key kept": PDFBytes.contains("catalog-custom-marker", in: out),
                "custom page key kept": PDFBytes.contains("page-custom-marker", in: out),
                "custom Info key kept": PDFBytes.contains("info-custom-marker", in: out),
                "custom trailer key kept": PDFBytes.contains("trailer-custom-marker", in: out),
                "original /ID kept": PDFBytes.contains(SpikeFixtures.originalID, in: out) || PDFBytes.contains(SpikeFixtures.originalID.lowercased(), in: out),
                "updated /ID kept": PDFBytes.contains(SpikeFixtures.updatedID, in: out) || PDFBytes.contains(SpikeFixtures.updatedID.lowercased(), in: out),
                "/OpenAction kept": PDFBytes.containsName("/OpenAction", in: out),
                "/PageLabels kept": PDFBytes.containsName("/PageLabels", in: out),
                "form value kept": PDFBytes.contains("form-value-marker", in: out),
                "latest text kept": text.contains("Revision two text"),
                "old revision text gone": !text.contains("Revision one text"),
                "Title kept": attributes[PDFDocumentAttribute.titleAttribute] as? String == "Updated Title",
                "Producer kept": attributes[PDFDocumentAttribute.producerAttribute] as? String == "Lectern raw writer",
                "object streams used": PDFBytes.containsName("/ObjStm", in: out),
                "xref stream used": PDFBytes.containsName("/XRef", in: out),
            ]
            for (key, value) in observations.sorted(by: { $0.key < $1.key }) { SpikeLog.note("Q6", "\(key): \(value)") }
            SpikeLog.note("Q6", "header=\(header) sizes: original=\(updated.count) rewritten=\(out.count) producer=\(String(describing: attributes[PDFDocumentAttribute.producerAttribute]))")

            let expected: [String: Bool] = [
                "original is prefix": false,
                "single %%EOF": true,
                "/Prev kept": false,
                "comment kept": false,
                "orphan object kept": false,
                "custom catalog key kept": false,
                "custom page key kept": false,
                "custom Info key kept": false,
                "custom trailer key kept": false,
                "original /ID kept": false,
                "updated /ID kept": false,
                "/OpenAction kept": false,
                "/PageLabels kept": false,
                "form value kept": true,
                "latest text kept": true,
                "old revision text gone": true,
                "Title kept": true,
                "Producer kept": false,
                "object streams used": false,
                "xref stream used": false,
            ]
            #expect(observations == expected)
            #expect(header.hasPrefix("%PDF-1.3"))
        }

        /// Form structure after a rewrite: /Fields no longer points at the
        /// widgets on the page (separate copies are written).
        @Test func rewriteDetachesWidgetsFromAcroFormFields() throws {
            let out = try #require(PDFDocument(data: SpikeFixtures.javaScriptProbe())?.dataRepresentation())
            SpikeArtifacts.save(out, as: "q6-form-rewritten.pdf")
            let objects = PDFBytes.objects(in: out)
            func body(_ number: Int) -> String { objects.first { $0.number == number }?.body ?? "" }
            func refs(_ text: Substring) -> [Int] {
                guard let regex = try? NSRegularExpression(pattern: "(\\d+) 0 R") else { return [] }
                let s = String(text), ns = s as NSString
                return regex.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap { Int(ns.substring(with: $0.range(at: 1))) }
            }
            /// The array value of `key` in `dict`, following one indirect reference.
            func array(_ key: String, in dict: String) -> [Int] {
                guard let range = dict.range(of: "\(key) ") else { return [] }
                let rest = dict[range.upperBound...]
                if rest.hasPrefix("[") { return refs(rest.prefix { $0 != "]" }) }
                guard let target = refs(rest.prefix { $0 != "R" } + "R").first else { return [] }
                return refs(Substring(body(target)))
            }
            func fieldName(_ number: Int) -> String? {
                let b = body(number)
                return b.range(of: "/T \\([^)]*\\)", options: .regularExpression).map { String(b[$0]) }
            }
            let page = try #require(objects.first { $0.body.contains("/Type /Page ") && $0.body.contains("/Annots") }?.body)
            let catalog = try #require(objects.first { $0.body.contains("/Type /Catalog") }?.body)
            let pageWidgets = array("/Annots", in: page).filter { body($0).contains("/Subtype /Widget") }
            let acroForm = try #require(refs(catalog[catalog.range(of: "/AcroForm ")!.upperBound...].prefix(12)).first)
            let fields = array("/Fields", in: body(acroForm))
            SpikeLog.note("Q6", "page widgets=\(pageWidgets) /Fields=\(fields)")
            #expect(pageWidgets.count == 12)
            #expect(fields.count == 12)
            #expect(Set(pageWidgets).isDisjoint(with: fields), "/Fields points at copies, not the page's widgets")
            #expect(Set(pageWidgets.compactMap(fieldName)) == Set(fields.compactMap(fieldName)), "the copies carry the same field names")
            #expect(PDFBytes.contains("/NeedAppearances true", in: out))
        }
    }
}

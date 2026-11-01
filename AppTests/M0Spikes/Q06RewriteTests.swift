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

            var expected: [String: Bool] = [
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
            if #available(macOS 27, *) {
                // macOS 27's rewrite keeps much more, but still drops /ID and the revision
                // history, and the original isn't a prefix: still no way to save (§4.3).
                for kept in ["orphan object kept", "custom catalog key kept", "custom page key kept", "custom Info key kept", "/OpenAction kept", "/PageLabels kept", "Producer kept"] {
                    expected[kept] = true
                }
            }
            #expect(observations == expected)
            if #available(macOS 27, *) {
                #expect(header.hasPrefix("%PDF-1.7"))
            } else {
                #expect(header.hasPrefix("%PDF-1.3"))
            }
        }

        /// Which link actions survive a rewrite (relevant to any Save a Copy
        /// that goes through PDFKit).
        @Test func linkActionsAfterRewrite() throws {
            let out = try #require(PDFDocument(data: SpikeFixtures.links())?.dataRepresentation())
            let reloaded = try #require(PDFDocument(data: out))
            var after: [String: String] = [:]
            for annotation in reloaded.page(at: 0)?.annotations ?? [] where annotation.type == "Link" {
                after[annotation.contents ?? "?"] = annotation.action?.type ?? "none"
            }
            SpikeLog.note("Q6", "link actions after rewrite: \(after.sorted { $0.key < $1.key })")
            #expect(after.count == SpikeFixtures.linkSpecs.count)
            if #available(macOS 27, *) {
                // macOS 27 keeps every action.
                #expect(after["launch"] == "Launch")
                #expect(after["submit"] == "SubmitForm")
                #expect(after["javascript"] == "JavaScript")
            } else {
                // Action types PDFKit models survive; Launch, SubmitForm and
                // JavaScript (exposed only as bare types) are dropped.
                for tag in ["launch", "submit", "javascript"] { #expect(after[tag] == "none", "\(tag)") }
            }
            for tag in ["uri-custom", "uri-https"] { #expect(after[tag] == "URI", "\(tag)") }
            for tag in ["goto-explicit", "goto-named", "dest-fit", "dest-named", "goto-xyz-null", "goto-fith", "goto-fitr", "goto-xyz-zoom"] {
                #expect(after[tag] == "GoTo", "\(tag)")
            }
            #expect(after["gotor"] == "GoToR")
            #expect(after["named-next"] == "Named")
            #expect(after["reset-form"] == "ResetForm")
            Q6Results.linkActions.withLock { $0 = after }
        }

        /// Form structure after a rewrite: /Fields no longer points at the
        /// widgets on the page (separate copies are written), before macOS 27.
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
            if #available(macOS 27, *) {
                // macOS 27 keeps the form whole: the AcroForm stays in the catalog and /Fields is
                // the page's own widgets.
                #expect(pageWidgets.count == 12)
                #expect(Set(array("/Fields", in: catalog)) == Set(pageWidgets))
                #expect(!PDFBytes.contains("/NeedAppearances true", in: out))
                return
            }
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

nonisolated enum Q6Results {
    static let linkActions = Locked<[String: String]>([:])
}

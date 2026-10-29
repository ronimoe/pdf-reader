import AppKit
import PDFKit
import Testing

extension M0bSpikes {
    /// Q5: what PDFKit adds to a new annotation, in memory and on serialisation.
    @Suite struct Q5AnnotationMetadata {
        static let types: [PDFAnnotationSubtype] = [.highlight, .underline, .strikeOut, .text]

        func makeAnnotated(configure: (PDFAnnotation) -> Void = { _ in }) throws -> (PDFDocument, [PDFAnnotation]) {
            let document = try #require(TestPDF.make(pageCount: 1).flatMap(PDFDocument.init(data:)))
            let page = try #require(document.page(at: 0))
            var made: [PDFAnnotation] = []
            let quad = [CGPoint(x: 0, y: 20), CGPoint(x: 200, y: 20), CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 0)].map { NSValue(point: $0) }
            for (index, type) in Self.types.enumerated() {
                let rect = type == .text
                    ? CGRect(x: 400, y: 600, width: 24, height: 24)
                    : CGRect(x: 72, y: 600 - index * 40, width: 200, height: 20)
                let annotation = PDFAnnotation(bounds: rect, forType: type, withProperties: nil)
                if type != .text { annotation.quadrilateralPoints = quad }
                annotation.contents = "comment \(index)"
                configure(annotation)
                page.addAnnotation(annotation)
                made.append(annotation)
            }
            return (document, made)
        }

        /// Top-level keys of each written annotation, by subtype.
        func serialisedKeys(_ data: Data) -> [String: [Set<String>]] {
            var keys: [String: [Set<String>]] = [:]
            for subtype in ["Highlight", "Underline", "StrikeOut", "Text", "Popup"] {
                keys[subtype] = PDFBytes.objects(containing: "/Subtype /\(subtype) ", in: data).map(PDFBytes.topLevelKeys(of:))
            }
            return keys
        }

        @Test func newAnnotationsGetAccountNameAndDateInMemory() throws {
            let (_, annotations) = try makeAnnotated()
            for annotation in annotations {
                let keys = annotation.annotationKeyValues.keys.map { "\($0)" }.sorted()
                SpikeLog.note("Q5", "\(annotation.type ?? "?") in memory: userName=\(String(describing: annotation.userName)) date=\(String(describing: annotation.modificationDate)) keys=\(keys)")
                // Filled from the macOS account, contrary to B4.
                #expect(annotation.userName == NSFullUserName(), "\(annotation.type ?? "")")
                #expect(annotation.modificationDate != nil, "\(annotation.type ?? "")")
                #expect(keys.contains("/T") && keys.contains("/M") && keys.contains("/P"))
            }
            #expect(annotations.last?.popup != nil, "a Text note gets a popup automatically")
        }

        @Test func serialisationWritesAuthorDateAndAppearance() throws {
            let (document, _) = try makeAnnotated()
            let data = try #require(document.dataRepresentation())
            SpikeArtifacts.save(data, as: "q5-annotations.pdf")
            let keys = serialisedKeys(data)
            for (subtype, sets) in keys.sorted(by: { $0.key < $1.key }) {
                SpikeLog.note("Q5", "\(subtype) written \(sets.count)x, keys: \(sets.map { $0.sorted() })")
            }
            let escapedName = SpikeRawPDF.escape(NSFullUserName())
            #expect(PDFBytes.count("/T (\(escapedName))", in: data) >= 4)
            for subtype in ["Highlight", "Underline", "StrikeOut", "Text"] {
                let set = try #require(keys[subtype]?.first, "\(subtype) written")
                #expect(set.isSuperset(of: ["/T", "/M", "/AP", "/Contents", "/F", "/Border", "/DA", "/C"]), "\(subtype): \(set.sorted())")
                #expect(!set.contains("/NM") && !set.contains("/CreationDate") && !set.contains("/P"), "\(subtype): \(set.sorted())")
            }
            // The Text note and its Popup are each written twice.
            #expect(keys["Text"]?.count == 2)
            #expect(keys["Popup"]?.count == 2)
            #expect(keys["Popup"]?.first?.contains("/M") == true)
        }

        @Test func clearingUserNameAndDateKeepsThemOutOfTheFile() throws {
            let (document, annotations) = try makeAnnotated { annotation in
                annotation.userName = nil
                annotation.modificationDate = nil
            }
            for annotation in annotations {
                #expect(annotation.userName == nil)
                #expect(annotation.modificationDate == nil)
            }
            let data = try #require(document.dataRepresentation())
            let keys = serialisedKeys(data)
            for (subtype, sets) in keys.sorted(by: { $0.key < $1.key }) {
                SpikeLog.note("Q5", "cleared: \(subtype) keys: \(sets.map { $0.sorted() })")
            }
            #expect(!PDFBytes.contains(SpikeRawPDF.escape(NSFullUserName()), in: data))
            for subtype in ["Highlight", "Underline", "StrikeOut", "Text"] {
                let set = try #require(keys[subtype]?.first)
                #expect(!set.contains("/T"), "\(subtype)")
                #expect(!set.contains("/M"), "\(subtype)")
            }
            // The automatically created Popup keeps its own date…
            #expect(keys["Popup"]?.allSatisfy { $0.contains("/M") } == true)
        }

        @Test func popupDateMustBeClearedSeparately() throws {
            let (document, _) = try makeAnnotated { annotation in
                annotation.userName = nil
                annotation.modificationDate = nil
                annotation.popup?.modificationDate = nil
                annotation.popup?.userName = nil
            }
            let data = try #require(document.dataRepresentation())
            let keys = serialisedKeys(data)
            #expect(keys["Popup"]?.isEmpty == false)
            #expect(keys["Popup"]?.allSatisfy { !$0.contains("/M") && !$0.contains("/T") } == true)
        }

        @Test func explicitUserNameIsWrittenAsT() throws {
            let (document, _) = try makeAnnotated { $0.userName = "Reader Name" }
            let data = try #require(document.dataRepresentation())
            #expect(PDFBytes.count("/T (Reader Name)", in: data) >= 4)
            #expect(!PDFBytes.contains(SpikeRawPDF.escape(NSFullUserName()), in: data))
        }
    }
}

import Foundation
import Testing
@testable import PDFSave

private func save(_ data: Data, _ changes: [AnnotationChange] = [.testNote],
                  options: IncrementalWriter.Options = .init()) throws(PDFSaveError) -> SaveResult {
    try IncrementalWriter(options: options).saveInPlace(original: data, changes: changes)
}

/// Malformed input must come back as a `PDFSaveError`, never a trap.
@Suite struct MalformedInputTests {
    func expectMalformed(_ data: Data, sourceLocation: SourceLocation = #_sourceLocation) {
        let error = #expect(throws: PDFSaveError.self, sourceLocation: sourceLocation) { try save(data) }
        if let error, case .malformed = error {} else {
            Issue.record("expected .malformed, got \(String(describing: error))", sourceLocation: sourceLocation)
        }
    }

    @Test func sizeTooLargeForInt() {
        // Parses as a real; converting it with Int(_:) used to trap.
        expectMalformed(TestPDF.pages(1).finishTable(trailer: "/Size 100000000000000000000 /Root 1 0 R"))
    }

    @Test func sizeIntMax() {
        expectMalformed(TestPDF.pages(1).finishTable(trailer: "/Size 9223372036854775807 /Root 1 0 R"))
    }

    @Test func streamLengthIntMax() {
        expectMalformed(TestPDF.pages(1).finishStream(number: 6, trailer: "/Root 1 0 R", length: "9223372036854775807"))
    }

    @Test func streamLengthWrong() {
        expectMalformed(TestPDF.pages(1).finishStream(number: 6, trailer: "/Root 1 0 R", length: "3"))
    }

    @Test func xrefStmNegative() {
        expectMalformed(TestPDF.pages(1).finishTable(trailer: "/Size 4 /Root 1 0 R /XRefStm -5"))
    }

    @Test func prevNotAnInteger() {
        expectMalformed(TestPDF.pages(1).finishTable(trailer: "/Size 4 /Root 1 0 R /Prev /Nope"))
    }

    @Test func indexNegativeCount() {
        expectMalformed(TestPDF.pages(1).finishStream(
            number: 6, trailer: "", dict: "/Type /XRef /W [1 4 2] /Index [0 -1] /Size {SIZE} /Root 1 0 R"))
    }

    @Test func indexOverflows() {
        expectMalformed(TestPDF.pages(1).finishStream(
            number: 6, trailer: "", dict: "/Type /XRef /W [1 4 2] /Index [9223372036854775807 2] /Size {SIZE} /Root 1 0 R"))
    }

    @Test func tableSubsectionOverflows() {
        let sub = "9223372036854775807 2\n0000000000 00000 f\r\n0000000000 00000 f\r\n"
        expectMalformed(TestPDF.pages(1).finishTable(trailer: "/Size 4 /Root 1 0 R", subsectionOverride: sub))
    }

    @Test func objectStreamNegativeOffset() {
        var pdf = TestPDF()
        pdf.obj(1, "<< /Type /Catalog /Pages 2 0 R >>")
        pdf.objStm(5, [(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"), (3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 9 9] >>")],
                   headerOverride: "2 0 3 -50")
        expectMalformed(pdf.finishStream(number: 6, trailer: "/Root 1 0 R"))
    }

    @Test func predictorColumnsHuge() {
        let pdf = TestPDF.pages(1)
        let rows = pdf.xrefRows(selfNumber: 6, selfOffset: 0)
        expectMalformed(pdf.finishStream(
            number: 6, trailer: "",
            dict: "/Type /XRef /W [1 4 2] /Index [{INDEX}] /Size {SIZE} /Root 1 0 R /Filter /FlateDecode "
                + "/DecodeParms << /Predictor 12 /Columns 1099511627776 >>",
            data: TestPDF.zlib(rows.rows)))
    }

    @Test func predictorBitsPerComponentInvalid() {
        let pdf = TestPDF.pages(1)
        let rows = pdf.xrefRows(selfNumber: 6, selfOffset: 0)
        expectMalformed(pdf.finishStream(
            number: 6, trailer: "",
            dict: "/Type /XRef /W [1 4 2] /Index [{INDEX}] /Size {SIZE} /Root 1 0 R /Filter /FlateDecode "
                + "/DecodeParms << /Predictor 12 /Columns 7 /BitsPerComponent 3 >>",
            data: TestPDF.zlib(rows.rows)))
    }

    @Test func inflateBomb() {
        // 20 MB of zeros deflates to ~20 KB: far past the 64× (1 MB floor) structural limit.
        let bomb = TestPDF.zlib([UInt8](repeating: 0, count: 20 << 20))
        #expect(throws: PDFSaveError.malformed("Flate stream inflates past \(StreamDecoder.outputLimit(forInput: bomb.count)) bytes")) {
            _ = try StreamDecoder.inflate(bomb)
        }
        expectMalformed(TestPDF.pages(1).finishStream(
            number: 6, trailer: "", dict: "/Type /XRef /W [1 4 2] /Index [{INDEX}] /Size {SIZE} /Root 1 0 R /Filter /FlateDecode",
            data: bomb))
    }

    @Test func staleXRefOffset() {
        var pdf = TestPDF.pages(1)
        pdf.offsets[3]! -= 5
        let error = #expect(throws: PDFSaveError.self) { try save(pdf.finishTable(trailer: "/Size 4 /Root 1 0 R")) }
        if let error, case .malformed = error {} else { Issue.record("expected .malformed, got \(String(describing: error))") }
    }

    /// Deterministic fuzzing: random byte mutations and truncations of the corpus. Every run must
    /// either throw a PDFSaveError or produce an output that passes the writer's own verification.
    @Test func fuzzCorpusMutations() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Repo.corpus, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "pdf" && !$0.lastPathComponent.hasPrefix("encrypted") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try [UInt8](Data(contentsOf: $0)) }
        try Self.fuzz(files, iterations: 2000, seed: 0x4C45_4354_4552_4E00, label: "generated")
    }

    /// The same over the real-world files (MB-sized, so fewer iterations). Mutations also hit the
    /// head, where linearized files keep their first-page cross-reference section.
    @Test func fuzzRealWorldMutations() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Repo.realWorld, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "pdf" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try [UInt8](Data(contentsOf: $0)) }
        try #require(files.count >= 9)
        try Self.fuzz(files, iterations: 600, seed: 0x5245_414C_574F_524C, label: "real-world")
    }

    static func fuzz(_ files: [[UInt8]], iterations: Int, seed: UInt64, label: String) throws {
        try #require(!files.isEmpty)
        var rng = SplitMix64(seed: seed)
        var succeeded = 0, refused = 0
        let alphabet = Array("0123456789 -/<>[]R".utf8)
        let start = ContinuousClock.now
        for _ in 0..<iterations {
            var bytes = files[Int(rng.next() % UInt64(files.count))]
            switch rng.next() % 5 {
            case 0:  // truncate
                bytes = Array(bytes.prefix(1 + Int(rng.next() % UInt64(bytes.count))))
            case 1:  // random bytes anywhere
                for _ in 0..<(1 + rng.next() % 4) { bytes[Int(rng.next() % UInt64(bytes.count))] = UInt8(truncatingIfNeeded: rng.next()) }
            case 2:  // digits and delimiters in the head (linearization dictionary, first-page xref)
                let head = min(bytes.count, 4096)
                for _ in 0..<(1 + rng.next() % 3) {
                    bytes[Int(rng.next() % UInt64(head))] = alphabet[Int(rng.next() % UInt64(alphabet.count))]
                }
            default:  // digits and delimiters in the structural tail, where the xref and trailer live
                let tail = min(bytes.count, 600)
                for _ in 0..<(1 + rng.next() % 3) {
                    let at = bytes.count - 1 - Int(rng.next() % UInt64(tail))
                    bytes[at] = alphabet[Int(rng.next() % UInt64(alphabet.count))]
                }
            }
            // Neither the pre-check nor the save may trap; the copy path exercises the writer on
            // signed and Reader-extended inputs too.
            _ = Saveability.evaluate(Data(bytes))
            do {
                let result = try IncrementalWriter().saveCopy(original: Data(bytes), changes: [.testNote])
                #expect(result.data.prefix(bytes.count) == Data(bytes))
                succeeded += 1
            } catch {
                refused += 1
            }
        }
        print("fuzz \(label): \(iterations) mutations, \(succeeded) saved, \(refused) refused, \(ContinuousClock.now - start)")
        #expect(succeeded + refused == iterations)
        #expect(succeeded > 0 && refused > 0, "fuzz should hit both outcomes (\(succeeded) saved, \(refused) refused)")
    }
}

struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Structural edge cases found in review.
@Suite struct WriterReviewTests {
    @Test func sharedAnnotsArrayIsNotEditedForOtherPages() throws {
        var pdf = TestPDF.pages(2, pageExtra: [0: "/Annots 5 0 R ", 1: "/Annots 5 0 R "])
        pdf.obj(5, "[]")
        let original = pdf.finishTable(trailer: "/Size 6 /Root 1 0 R")
        let result = try save(original)
        // Page 1 gets its own direct array; the shared array object 5 is left alone.
        #expect(result.rewrittenObjects == [ObjectRef(3, 0)])
        let reread = try PDFSaveDocument(data: result.data)
        #expect(try reread.annotations(onPage: 0).map(\.subtype) == ["Text"])
        #expect(try reread.annotations(onPage: 1).isEmpty)
        #expect(try reread.object(ObjectRef(5, 0)) == .array([]))
    }

    @Test func unsharedIndirectAnnotsArrayIsRewrittenInPlace() throws {
        var pdf = TestPDF.pages(2, pageExtra: [0: "/Annots 5 0 R "])
        pdf.obj(5, "[]")
        let result = try save(pdf.finishTable(trailer: "/Size 6 /Root 1 0 R"))
        #expect(result.rewrittenObjects == [ObjectRef(5, 0)])
    }

    @Test func duplicateKeysLastValueWinsAndIsFlagged() throws {
        var p = PDFParser(bytes: Array("<< /A 1 /B 2 /A 3 >>".utf8))
        let dict = try #require(try p.parseObject().dictionaryValue)
        #expect(dict["A"] == .integer(3))  // qpdf, MuPDF and Poppler keep the last value
        #expect(dict.hasDuplicateKeys)
        var q = PDFParser(bytes: Array("<< /A 1 /B 2 >>".utf8))
        #expect(try q.parseObject().dictionaryValue?.hasDuplicateKeys == false)
    }

    @Test func refusesToRewritePageWithDuplicateKeys() throws {
        let pdf = TestPDF.pages(1, pageExtra: [0: "/MediaBox [0 0 50 50] "])
        let error = #expect(throws: PDFSaveError.self) { try save(pdf.finishTable(trailer: "/Size 4 /Root 1 0 R")) }
        if let error, case .unsupported = error {} else { Issue.record("expected .unsupported, got \(String(describing: error))") }
    }

    @Test func refusesToEditAnnotationWithDuplicateKeys() throws {
        var pdf = TestPDF.pages(1, pageExtra: [0: "/Annots [5 0 R] "])
        pdf.obj(5, "<< /Type /Annot /Subtype /Text /Rect [0 0 9 9] /Contents (a) /Contents (b) >>")
        let error = #expect(throws: PDFSaveError.self) {
            try save(pdf.finishTable(trailer: "/Size 6 /Root 1 0 R"), [.editContents(ObjectRef(5, 0), "x")])
        }
        if let error, case .unsupported = error {} else { Issue.record("expected .unsupported, got \(String(describing: error))") }
    }

    static func threadPDF() -> Data {
        // 5 is a note; 6 replies to 5; 7 replies to 6 and has popup 8; 9 is unrelated.
        var pdf = TestPDF.pages(1, pageExtra: [0: "/Annots [5 0 R 6 0 R 7 0 R 8 0 R 9 0 R] "])
        pdf.obj(5, "<< /Type /Annot /Subtype /Text /Rect [0 0 9 9] /Contents (root) >>")
        pdf.obj(6, "<< /Type /Annot /Subtype /Text /Rect [0 0 9 9] /Contents (reply) /IRT 5 0 R >>")
        pdf.obj(7, "<< /Type /Annot /Subtype /Text /Rect [0 0 9 9] /Contents (reply to reply) /IRT 6 0 R /Popup 8 0 R >>")
        pdf.obj(8, "<< /Type /Annot /Subtype /Popup /Rect [0 0 9 9] /Parent 7 0 R >>")
        pdf.obj(9, "<< /Type /Annot /Subtype /Square /Rect [0 0 9 9] /Contents (other) >>")
        return pdf.finishTable(trailer: "/Size 10 /Root 1 0 R")
    }

    @Test func deleteRemovesRepliesTransitively() throws {
        let result = try save(Self.threadPDF(), [.delete(ObjectRef(5, 0))])
        #expect(Set(result.removedAnnotations) == Set([5, 6, 7, 8].map { ObjectRef($0, 0) }))
        #expect(try PDFSaveDocument(data: result.data).annotations(onPage: 0).map(\.ref) == [ObjectRef(9, 0)])
    }

    @Test func editingADeletedAnnotationIsRefused() {
        let data = Self.threadPDF()
        // Either order, and also when it goes only as a reply of the deleted annotation.
        #expect(throws: PDFSaveError.annotationNotFound(ObjectRef(9, 0))) {
            try save(data, [.delete(ObjectRef(9, 0)), .editContents(ObjectRef(9, 0), "x")])
        }
        #expect(throws: PDFSaveError.annotationNotFound(ObjectRef(9, 0))) {
            try save(data, [.editContents(ObjectRef(9, 0), "x"), .delete(ObjectRef(9, 0))])
        }
        #expect(throws: PDFSaveError.annotationNotFound(ObjectRef(7, 0))) {
            try save(data, [.editContents(ObjectRef(7, 0), "x"), .delete(ObjectRef(5, 0))])
        }
    }

    @Test func editingFreeTextDropsStaleAppearance() throws {
        var pdf = TestPDF.pages(1, pageExtra: [0: "/Annots [5 0 R] "])
        pdf.obj(5, "<< /Type /Annot /Subtype /FreeText /Rect [0 0 90 20] /Contents (old) /DA (/Helv 12 Tf 0 g) "
            + "/RC (<body>old</body>) /AP << /N 6 0 R >> >>")
        pdf.stream(6, dict: "/Type /XObject /Subtype /Form /BBox [0 0 90 20]", data: Array("BT (old) Tj ET".utf8))
        let result = try save(pdf.finishTable(trailer: "/Size 7 /Root 1 0 R"), [.editContents(ObjectRef(5, 0), "new")])
        let dict = try #require(try PDFSaveDocument(data: result.data).dictionary(ObjectRef(5, 0)))
        #expect(dict["Contents"]?.stringValue?.text == "new")
        #expect(dict["AP"] == nil)
        #expect(dict["RC"] == nil)
        #expect(dict["DA"] != nil)
    }

    @Test func editingOtherAnnotationsKeepsAppearance() throws {
        var pdf = TestPDF.pages(1, pageExtra: [0: "/Annots [5 0 R] "])
        pdf.obj(5, "<< /Type /Annot /Subtype /Square /Rect [0 0 9 9] /Contents (old) /AP << /N 6 0 R >> >>")
        pdf.stream(6, dict: "/Type /XObject /Subtype /Form /BBox [0 0 9 9]", data: Array("0 0 9 9 re S".utf8))
        let result = try save(pdf.finishTable(trailer: "/Size 7 /Root 1 0 R"), [.editContents(ObjectRef(5, 0), "new")])
        #expect(try PDFSaveDocument(data: result.data).dictionary(ObjectRef(5, 0))?["AP"] != nil)
    }

    // MARK: Hybrid files and indirect /Length

    /// Object 3 (the page) is in an object stream listed by the /XRefStm. The table either also
    /// lists a different, uncompressed copy of 3, or marks 3 as free.
    static func hybrid(tableListsUncompressedCopy: Bool) -> Data {
        var pdf = TestPDF()
        pdf.obj(1, "<< /Type /Catalog /Pages 2 0 R >>")
        pdf.obj(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        if tableListsUncompressedCopy { pdf.obj(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] >>") }
        pdf.objStm(5, [(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 999 999] >>")])
        let stmOffset = pdf.out.count
        let rows = pdf.xrefRows(selfNumber: 6, selfOffset: stmOffset, only: [3])
        pdf.stream(6, dict: "/Type /XRef /W [1 4 2] /Index [\(rows.index)] /Size 7", data: rows.rows)
        let extra = tableListsUncompressedCopy ? [:] : [3: "0000000000 00000 f\r\n"]
        return pdf.finishTable(trailer: "/Size 7 /Root 1 0 R /XRefStm \(stmOffset)", extra: extra)
    }

    @Test func hybridTableEntryWinsOverXRefStm() throws {
        let doc = try PDFSaveDocument(data: Self.hybrid(tableListsUncompressedCopy: true))
        // Object 3 is listed in the table (offset) and in the stream (compressed): the table wins.
        let box = try doc.dictionary(ObjectRef(3, 0))?["MediaBox"]?.arrayValue?.compactMap(\.intValue)
        #expect(box == [0, 0, 300, 300])
    }

    @Test func hybridFreeTableEntryHidesCompressedObject() {
        // qpdf and MuPDF both let a free table entry hide the /XRefStm entry; so do we, which leaves
        // the page tree without its page.
        let data = Self.hybrid(tableListsUncompressedCopy: false)
        let error = #expect(throws: PDFSaveError.self) { try PDFSaveDocument(data: data) }
        if let error, case .malformed = error {} else { Issue.record("expected .malformed, got \(String(describing: error))") }
    }

    @Test func hybridCompressedObjectOnlyInXRefStm() throws {
        // Object 3 is absent from the table, so the /XRefStm copy is used.
        var pdf = TestPDF()
        pdf.obj(1, "<< /Type /Catalog /Pages 2 0 R >>")
        pdf.obj(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        pdf.objStm(5, [(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 999 999] >>")])
        let stmOffset = pdf.out.count
        let rows = pdf.xrefRows(selfNumber: 6, selfOffset: stmOffset, only: [3])
        pdf.stream(6, dict: "/Type /XRef /W [1 4 2] /Index [\(rows.index)] /Size 7", data: rows.rows)
        let result = try save(pdf.finishTable(trailer: "/Size 7 /Root 1 0 R /XRefStm \(stmOffset)"))
        #expect(result.xrefKind == .table)
        #expect(result.rewrittenObjects == [ObjectRef(3, 0)])
    }

    @Test func indirectStreamLength() throws {
        // The page tree lives in an object stream whose /Length is a reference (8 0 R).
        var pdf = TestPDF()
        pdf.obj(1, "<< /Type /Catalog /Pages 2 0 R >>")
        let members = [(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"), (3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 99 99] >>")]
        var header = "", body = ""
        for (n, text) in members { header += "\(n) \(body.utf8.count) "; body += text + "\n" }
        header += "\n"
        let data = Array((header + body).utf8)
        pdf.stream(5, dict: "/Type /ObjStm /N 2 /First \(header.utf8.count)", data: data, length: "8 0 R")
        pdf.compressed[2] = (5, 0)
        pdf.compressed[3] = (5, 1)
        pdf.obj(8, String(data.count))
        let result = try save(pdf.finishStream(number: 9, trailer: "/Root 1 0 R"))
        #expect(result.xrefKind == .stream)
        #expect(try PDFSaveDocument(data: result.data).annotations(onPage: 0).count == 1)
    }

    // MARK: Post-write verification

    @Test func verificationCatchesCorruptedUpdate() throws {
        let original = TestPDF.pages(2).finishTable(trailer: "/Size 5 /Root 1 0 R")
        var options = IncrementalWriter.Options()
        // Change one byte of the new annotation's /Name after it was written.
        options.testHooks.mutateOutput = { out in
            let needle = Array("/Comment".utf8)
            if let at = PDFParser.find(needle, in: out, from: 0) { out[at + 1] = UInt8(ascii: "X") }
        }
        #expect(throws: PDFSaveError.verificationFailed("object 5 0 R does not read back identically")) {
            try save(original, options: options)
        }
    }

    @Test func verificationCatchesChangedOriginalBytes() throws {
        let original = TestPDF.pages(1).finishTable(trailer: "/Size 4 /Root 1 0 R")
        var options = IncrementalWriter.Options()
        options.testHooks.mutateOutput = { out in out[3] = UInt8(ascii: "X") }
        #expect(throws: PDFSaveError.verificationFailed("original bytes are not a prefix of the output")) {
            try save(original, options: options)
        }
    }

    @Test func verificationCatchesChangesToUntouchedPages() throws {
        var pdf = TestPDF.pages(2, pageExtra: [1: "/Annots [5 0 R] "])
        pdf.obj(5, "<< /Type /Annot /Subtype /Square /Rect [0 0 9 9] /Contents (keep) >>")
        let original = pdf.finishTable(trailer: "/Size 6 /Root 1 0 R")

        // An extra, undeclared rewrite of page 2's /Annots.
        var dropAnnot = IncrementalWriter.Options()
        dropAnnot.testHooks.mutateWritten = { written in
            written[ObjectRef(4, 0)] = .dictionary(["Type": .name("Page"), "Parent": .reference(ObjectRef(2, 0)),
                                                    "MediaBox": .array([0, 0, 200, 200].map(PDFObject.integer)),
                                                    "Annots": .array([])])
        }
        #expect(throws: PDFSaveError.verificationFailed("page 2 /Annots does not read back as expected")) {
            try save(original, options: dropAnnot)
        }

        // An undeclared change to an annotation on an untouched page.
        var editAnnot = IncrementalWriter.Options()
        editAnnot.testHooks.mutateWritten = { written in
            written[ObjectRef(5, 0)] = .dictionary(["Type": .name("Annot"), "Subtype": .name("Square"),
                                                    "Rect": .array([0, 0, 9, 9].map(PDFObject.integer)),
                                                    "Contents": .text("changed")])
        }
        #expect(throws: PDFSaveError.verificationFailed("annotation 5 0 R on page 2 changed")) {
            try save(original, options: editAnnot)
        }

        // An undeclared change to an untouched page object that keeps its /Annots.
        var editPage = IncrementalWriter.Options()
        editPage.testHooks.mutateWritten = { written in
            written[ObjectRef(4, 0)] = .dictionary(["Type": .name("Page"), "Parent": .reference(ObjectRef(2, 0)),
                                                    "MediaBox": .array([0, 0, 999, 999].map(PDFObject.integer)),
                                                    "Annots": .array([.reference(ObjectRef(5, 0))])])
        }
        #expect(throws: PDFSaveError.verificationFailed("untouched page 2 changed")) {
            try save(original, options: editPage)
        }
    }
}

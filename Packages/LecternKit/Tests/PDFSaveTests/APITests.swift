import Foundation
import Testing
@testable import PDFSave

private let quad = Quad(rect: PDFRect(x: 20, y: 100, width: 120, height: 12))

private func page1(_ extra: String = "", objects: [(Int, String)] = [], size: Int? = nil) -> Data {
    var pdf = TestPDF.pages(1, pageExtra: [0: extra])
    for (n, body) in objects { pdf.obj(n, body) }
    return pdf.finishTable(trailer: "/Size \(size ?? (objects.map(\.0).max() ?? 3) + 1) /Root 1 0 R")
}

private func annotation(_ result: SaveResult, _ ref: ObjectRef) throws -> PDFDictionary {
    try #require(try PDFSaveDocument(data: result.data).dictionary(ref))
}

/// B4: nothing personal or dated is written unless the caller passes it.
@Suite struct PrivacyTests {
    static let allowedKeys: Set<PDFName> = ["Type", "Subtype", "Rect", "P", "F", "C", "NM", "QuadPoints", "AP", "Contents",
                                            "Name", "Open"]

    @Test func newAnnotationsCarryNoDateOrAuthor() throws {
        let original = page1()
        let result = try IncrementalWriter().saveInPlace(original: original, changes: [
            .addMarkup(NewMarkup(kind: .highlight, pageIndex: 0, quads: [quad], contents: "c")),
            .addMarkup(NewMarkup(kind: .underline, pageIndex: 0, quads: [quad])),
            .addMarkup(NewMarkup(kind: .strikeOut, pageIndex: 0, quads: [quad], author: "")),
            .addNote(NewNote(pageIndex: 0, origin: PDFPoint(x: 5, y: 5), contents: "n")),
        ])
        for added in result.added {
            let keys = Set(try annotation(result, added.ref).keys)
            #expect(keys.isSubset(of: Self.allowedKeys), "\(added.subtype): \(keys.subtracting(Self.allowedKeys))")
        }
        let update = String(decoding: result.data.suffix(from: original.count), as: UTF8.self)
        for forbidden in ["/M ", "/CreationDate", "/T ", "D:20"] { #expect(!update.contains(forbidden), "\(forbidden)") }
        // PDFKit fills in NSFullUserName() on its own annotations (M0b Q5); the writer never does.
        let fullName = NSFullUserName()
        if !fullName.isEmpty {
            #expect(!update.contains(fullName))
            let update = [UInt8](result.data.suffix(from: original.count))
            #expect(PDFParser.find(PDFString(text: fullName).bytes, in: update, from: 0) == nil)
        }
    }

    @Test func authorAndDateOnlyWhenPassed() throws {
        let date = Date(timeIntervalSince1970: 1_793_000_000)
        let result = try IncrementalWriter(options: .init(modificationDate: date)).saveInPlace(original: page1(), changes: [
            .addNote(NewNote(pageIndex: 0, origin: PDFPoint(x: 5, y: 5), contents: "n", author: "Ann")),
        ])
        let d = try annotation(result, result.added[0].ref)
        #expect(d["T"]?.stringValue?.text == "Ann")
        #expect(d["M"]?.stringValue?.text == "D:20261026073320Z")
        #expect(d["CreationDate"] == d["M"])
    }

    @Test func editsLeaveDatesAloneUnlessPassed() throws {
        let original = page1("/Annots [5 0 R] ", objects: [(5, "<< /Type /Annot /Subtype /Square /Rect [0 0 9 9] /M (D:19990101) >>")])
        let plain = try IncrementalWriter().saveInPlace(original: original, changes: [.editContents(ObjectRef(5), "x")])
        #expect(try annotation(plain, ObjectRef(5))["M"]?.stringValue?.text == "D:19990101")
        let dated = try IncrementalWriter(options: .init(modificationDate: Date(timeIntervalSince1970: 0)))
            .saveInPlace(original: original, changes: [.editContents(ObjectRef(5), "x")])
        #expect(try annotation(dated, ObjectRef(5))["M"]?.stringValue?.text == "D:19700101000000Z")
    }
}

@Suite struct NameTests {
    @Test func everyNewAnnotationGetsAUniqueLecternName() throws {
        let changes: [AnnotationChange] = (0..<20).map { i in
            i % 2 == 0 ? .addMarkup(NewMarkup(kind: .highlight, pageIndex: 0, quads: [quad]))
                : .addNote(NewNote(pageIndex: 0, origin: PDFPoint(x: 5, y: 5), contents: nil))
        }
        let result = try IncrementalWriter().saveInPlace(original: page1(), changes: changes)
        let names = result.added.map(\.name)
        #expect(Set(names).count == 20)
        #expect(names.allSatisfy { $0.hasPrefix("lectern-") && UUID(uuidString: String($0.dropFirst(8))) != nil })
        let descriptors = try PDFSaveDocument(data: result.data).annotations(onPage: 0)
        #expect(descriptors.map(\.name) == names)
        #expect(descriptors.allSatisfy { $0.isLectern })
        // The change's name is the one written, so the journal and the app agree with the file.
        if case .addMarkup(let m) = changes[0] { #expect(names[0] == m.name) }
    }

    @Test func duplicateNamesAreRefused() throws {
        let note = NewNote(pageIndex: 0, origin: PDFPoint(x: 5, y: 5), contents: nil, name: "lectern-same")
        #expect(throws: PDFSaveError.duplicateName("lectern-same")) {
            try IncrementalWriter().saveInPlace(original: page1(), changes: [.addNote(note), .addNote(note)])
        }
        let existing = page1("/Annots [5 0 R] ", objects: [(5, "<< /Type /Annot /Subtype /Text /Rect [0 0 9 9] /NM (lectern-same) >>")])
        #expect(throws: PDFSaveError.duplicateName("lectern-same")) {
            try IncrementalWriter().saveInPlace(original: existing, changes: [.addNote(note)])
        }
    }

    @Test func changesRoundTripThroughJSON() throws {
        let changes: [AnnotationChange] = [
            .addMarkup(NewMarkup(kind: .strikeOut, pageIndex: 2, quads: [quad], color: PDFRGBColor(red: 0.1, green: 0.2, blue: 0.3),
                                 contents: "é ✓", author: "A")),
            .addNote(NewNote(pageIndex: 0, origin: PDFPoint(x: 1, y: 2), contents: nil)),
            .editContents(ObjectRef(7, 1), nil), .editColor(ObjectRef(8), .yellow), .delete(ObjectRef(9)),
        ]
        let data = try JSONEncoder().encode(changes)
        #expect(try JSONDecoder().decode([AnnotationChange].self, from: data) == changes)
    }
}

@Suite struct MarkupAppearanceTests {
    func appearance(_ kind: MarkupKind) throws -> (PDFDictionary, String) {
        let result = try IncrementalWriter().saveInPlace(original: page1(), changes: [
            .addMarkup(NewMarkup(kind: kind, pageIndex: 0, quads: [quad], color: PDFRGBColor(red: 1, green: 0, blue: 0))),
        ])
        let doc = try PDFSaveDocument(data: result.data)
        let d = try #require(try doc.dictionary(result.added[0].ref))
        let apRef = try #require(d["AP"]?.dictionaryValue?["N"]?.referenceValue)
        guard case .stream(let s) = try doc.object(apRef) else { throw CorpusFailure("no AP stream") }
        return (d, String(decoding: s.rawData, as: UTF8.self))
    }

    @Test func underlineAndStrikeOutAreStrokedLines() throws {
        for (kind, y) in [(MarkupKind.underline, "101.2"), (.strikeOut, "105.4")] {
            let (d, ops) = try appearance(kind)
            #expect(d["Subtype"]?.nameValue?.string == kind.subtype)
            #expect(d["QuadPoints"]?.arrayValue?.count == 8)
            #expect(ops.contains("1 0 0 RG"))
            #expect(ops.contains("20 \(y) m 140 \(y) l S"), "\(kind): \(ops)")
            #expect(!ops.contains(" rg"))  // stroked, not filled
        }
    }

    @Test func highlightIsFilledWithMultiply() throws {
        let (_, ops) = try appearance(.highlight)
        #expect(ops.contains("/LecternHL gs") && ops.contains("1 0 0 rg") && ops.hasSuffix("f"))
    }
}

@Suite struct EditTests {
    static let green = PDFRGBColor(red: 0, green: 1, blue: 0)

    static func file(_ annot: String) -> Data {
        page1("/Annots [5 0 R] ", objects: [
            (5, annot),
            (6, "<< /Type /XObject /Subtype /Form /BBox [0 0 9 9] >>"),
        ])
    }

    @Test func colourEditRegeneratesMarkupAppearance() throws {
        // QuadPoints in the counter-clockwise order some writers use; the new /AP must still be a clean box.
        let original = Self.file("<< /Type /Annot /Subtype /Highlight /Rect [10 10 50 20] /C [1 1 0] "
            + "/QuadPoints [10 10 50 10 50 20 10 20] /AP << /N 6 0 R >> >>")
        let result = try IncrementalWriter().saveInPlace(original: original, changes: [.editColor(ObjectRef(5), Self.green)])
        let doc = try PDFSaveDocument(data: result.data)
        let d = try #require(try doc.dictionary(ObjectRef(5)))
        #expect(d["C"] == .array([.integer(0), .integer(1), .integer(0)]))
        let ap = try #require(d["AP"]?.dictionaryValue?["N"]?.referenceValue)
        #expect(ap != ObjectRef(6))
        guard case .stream(let s) = try doc.object(ap) else { Issue.record("no stream"); return }
        #expect(String(decoding: s.rawData, as: UTF8.self).contains("0 1 0 rg\n10 20 m\n50 20 l\n50 10 l\n10 10 l h"))
    }

    @Test func colourEditOfSomeoneElsesNoteDropsItsIcon() throws {
        let original = Self.file("<< /Type /Annot /Subtype /Text /Rect [0 0 20 20] /Name /Key /AP << /N 6 0 R >> >>")
        let result = try IncrementalWriter().saveInPlace(original: original, changes: [.editColor(ObjectRef(5), Self.green)])
        let d = try annotation(result, ObjectRef(5))
        #expect(d["AP"] == nil)
        #expect(d["Name"]?.nameValue == "Key")
    }

    @Test func colourEditOfOurNoteRedrawsOurIcon() throws {
        let first = try IncrementalWriter().saveInPlace(original: page1(), changes: [
            .addNote(NewNote(pageIndex: 0, origin: PDFPoint(x: 5, y: 5), contents: "n")),
        ])
        let ref = first.added[0].ref
        let oldAP = try annotation(first, ref)["AP"]
        let second = try IncrementalWriter().saveInPlace(original: first.data, changes: [.editColor(ref, Self.green)])
        let d = try annotation(second, ref)
        #expect(d["AP"] != nil && d["AP"] != oldAP)
    }

    @Test func colourEditOfOtherSubtypes() throws {
        let withAP = Self.file("<< /Type /Annot /Subtype /Square /Rect [0 0 9 9] /AP << /N 6 0 R >> >>")
        #expect(throws: PDFSaveError.unsupported("colour edit of a /Square annotation with an appearance stream")) {
            try IncrementalWriter().saveInPlace(original: withAP, changes: [.editColor(ObjectRef(5), Self.green)])
        }
        // Without an /AP, viewers draw from /C, so any subtype can change colour.
        let noAP = Self.file("<< /Type /Annot /Subtype /Square /Rect [0 0 9 9] /C [1 0 0] >>")
        let result = try IncrementalWriter().saveInPlace(original: noAP, changes: [.editColor(ObjectRef(5), Self.green)])
        #expect(try annotation(result, ObjectRef(5))["C"] == .array([.integer(0), .integer(1), .integer(0)]))
    }

    @Test func contentsEditDropsRichTextAndCanClear() throws {
        let original = Self.file("<< /Type /Annot /Subtype /Highlight /Rect [0 0 9 9] /Contents (old) /RC (<body>old</body>) "
            + "/AP << /N 6 0 R >> >>")
        let edited = try IncrementalWriter().saveInPlace(original: original, changes: [.editContents(ObjectRef(5), "new")])
        let d = try annotation(edited, ObjectRef(5))
        #expect(d["Contents"]?.stringValue?.text == "new" && d["RC"] == nil && d["AP"] != nil)
        let cleared = try IncrementalWriter().saveInPlace(original: original, changes: [.editContents(ObjectRef(5), nil)])
        #expect(try annotation(cleared, ObjectRef(5))["Contents"] == nil)
    }

    @Test func contentsAndColourInOneSave() throws {
        let original = Self.file("<< /Type /Annot /Subtype /Underline /Rect [0 0 90 9] /QuadPoints [0 9 90 9 0 0 90 0] "
            + "/AP << /N 6 0 R >> >>")
        let result = try IncrementalWriter().saveInPlace(original: original, changes: [
            .editContents(ObjectRef(5), "both"), .editColor(ObjectRef(5), Self.green),
        ])
        let d = try annotation(result, ObjectRef(5))
        #expect(d["Contents"]?.stringValue?.text == "both")
        #expect(d["C"] == .array([.integer(0), .integer(1), .integer(0)]))
        #expect(result.rewrittenObjects == [ObjectRef(5)])
    }
}

@Suite struct DescriptorTests {
    @Test func descriptorsReportWhatTheFileSays() throws {
        let data = page1("/Annots [5 0 R 6 0 R << /Type /Annot /Subtype /Link /Rect [1 1 2 2] >> 7 0 R 99 0 R] ", objects: [
            (5, "<< /Type /Annot /Subtype /Highlight /Rect [50 60 10 20] /NM (lectern-x) /T (Bo) /Contents <FEFF00E9> "
                + "/C [0.5] /Popup 6 0 R >>"),
            (6, "<< /Type /Annot /Subtype /Popup /Rect [0 0 9 9] /Parent 5 0 R /C [0 0 0 1] >>"),
            (7, "<< /Type /Annot /Subtype /Text /Rect [0 0 9 9] /IRT 5 0 R /C [] >>"),
        ])
        let d = try PDFSaveDocument(data: data).annotations(onPage: 0)
        #expect(d.map(\.subtype) == ["Highlight", "Popup", "Link", "Text"])  // dangling 99 0 R skipped
        #expect(d.map(\.indexInAnnots) == [0, 1, 2, 3])
        #expect(d[0].rect == PDFRect(x: 10, y: 20, width: 40, height: 40))
        #expect(d[0].name == "lectern-x" && d[0].isLectern && d[0].author == "Bo" && d[0].contents == "é")
        #expect(d[0].popup == ObjectRef(6) && d[0].color == .gray(0.5) && d[0].color?.rgb == PDFRGBColor(red: 0.5, green: 0.5, blue: 0.5))
        #expect(d[1].color == .cmyk(cyan: 0, magenta: 0, yellow: 0, black: 1) && d[1].color?.rgb == PDFRGBColor(red: 0, green: 0, blue: 0))
        #expect(d[2].ref == nil)
        #expect(d[3].inReplyTo == ObjectRef(5) && d[3].color == .transparent && d[3].color?.rgb == nil)
    }
}

@Suite struct MatcherTests {
    static func desc(_ n: Int, page: Int = 0, _ subtype: String = "Highlight", rect: PDFRect = PDFRect(x: 10, y: 10, width: 50, height: 10),
                     name: String? = nil, contents: String? = nil, inline: Bool = false) -> AnnotationDescriptor {
        AnnotationDescriptor(ref: inline ? nil : ObjectRef(n), pageIndex: page, indexInAnnots: 0, subtype: subtype, rect: rect,
                             name: name, contents: contents, author: nil, inReplyTo: nil, popup: nil, color: nil)
    }

    static let r = PDFRect(x: 10, y: 10, width: 50, height: 10)
    let m = AnnotationMatcher()

    @Test func nameMatchesExactlyAndNeverFallsBack() {
        let ds = [Self.desc(5, name: "lectern-a"), Self.desc(6)]
        #expect(m.match(AnnotationQuery(pageIndex: 0, subtype: "Highlight", rect: PDFRect(x: 0, y: 0, width: 1, height: 1),
                                        name: "lectern-a"), in: ds) == .matched(ObjectRef(5), .name))
        // An unknown name is not retried by position, even though object 6 sits exactly there.
        #expect(m.match(AnnotationQuery(pageIndex: 0, subtype: "Highlight", rect: Self.r, name: "lectern-new"), in: ds) == .notFound)
        // The name on another page or subtype is a conflict, not a match.
        #expect(m.match(AnnotationQuery(pageIndex: 1, subtype: "Highlight", rect: Self.r, name: "lectern-a"), in: ds)
            == .ambiguous([ObjectRef(5)]))
        #expect(m.match(AnnotationQuery(pageIndex: 0, subtype: "/Underline", rect: Self.r, name: "lectern-a"), in: ds)
            == .ambiguous([ObjectRef(5)]))
    }

    @Test func duplicateNamesNeedGeometry() {
        let ds = [Self.desc(5, name: "dup"), Self.desc(6, rect: PDFRect(x: 100, y: 10, width: 50, height: 10), name: "dup")]
        #expect(m.match(AnnotationQuery(pageIndex: 0, subtype: "Highlight", rect: Self.r, name: "dup"), in: ds)
            == .matched(ObjectRef(5), .nameAndGeometry))
        let twins = [Self.desc(5, name: "dup"), Self.desc(6, name: "dup")]
        #expect(m.match(AnnotationQuery(pageIndex: 0, subtype: "Highlight", rect: Self.r, name: "dup"), in: twins)
            == .ambiguous([ObjectRef(5), ObjectRef(6)]))
    }

    @Test func geometryWithinTolerance() {
        let ds = [Self.desc(5), Self.desc(6, page: 1), Self.desc(7, "Underline")]
        let q = AnnotationQuery(pageIndex: 0, subtype: "Highlight", rect: PDFRect(x: 10.04, y: 9.96, width: 50, height: 10))
        #expect(m.match(q, in: ds) == .matched(ObjectRef(5), .geometry))
        let far = AnnotationQuery(pageIndex: 0, subtype: "Highlight", rect: PDFRect(x: 10.2, y: 10, width: 50, height: 10))
        #expect(m.match(far, in: ds) == .notFound)
        #expect(AnnotationMatcher(tolerance: 0.5).match(far, in: ds) == .matched(ObjectRef(5), .geometry))
    }

    @Test func contentsBreakTiesOtherwiseAmbiguous() {
        let ds = [Self.desc(5, contents: "a"), Self.desc(6, contents: "b"), Self.desc(7)]
        #expect(m.match(AnnotationQuery(pageIndex: 0, subtype: "Highlight", rect: Self.r, contents: "b"), in: ds)
            == .matched(ObjectRef(6), .geometryAndContents))
        // nil and "" count as the same contents, and only 7 has none.
        #expect(m.match(AnnotationQuery(pageIndex: 0, subtype: "Highlight", rect: Self.r, contents: ""), in: ds)
            == .matched(ObjectRef(7), .geometryAndContents))
        #expect(m.match(AnnotationQuery(pageIndex: 0, subtype: "Highlight", rect: Self.r, contents: "c"), in: ds)
            == .ambiguous([ObjectRef(5), ObjectRef(6), ObjectRef(7)]))
    }

    @Test func batchIsOneToOne() {
        let ds = [Self.desc(5, contents: "x"), Self.desc(6, contents: "y")]
        let q = AnnotationQuery(pageIndex: 0, subtype: "Highlight", rect: Self.r, contents: "x")
        #expect(m.match([q, q], in: ds) == [.ambiguous([ObjectRef(5)]), .ambiguous([ObjectRef(5)])])
        let q2 = AnnotationQuery(pageIndex: 0, subtype: "Highlight", rect: Self.r, contents: "y")
        #expect(m.match([q, q2], in: ds) == [.matched(ObjectRef(5), .geometryAndContents), .matched(ObjectRef(6), .geometryAndContents)])
    }

    @Test func inlineAnnotationsAreUnaddressable() {
        #expect(m.match(AnnotationQuery(pageIndex: 0, subtype: "Link", rect: Self.r), in: [Self.desc(0, "Link", inline: true)])
            == .unaddressable)
    }

    @Test func notesCompareTheirTopLeftCorner() {
        // PDFKit reports a 20×20 note at 540,672 as 24×24 at 540,668.
        let ds = [Self.desc(5, "Text", rect: PDFRect(x: 540, y: 672, width: 20, height: 20))]
        #expect(m.match(AnnotationQuery(pageIndex: 0, subtype: "Text", rect: PDFRect(x: 540, y: 668, width: 24, height: 24)), in: ds)
            == .matched(ObjectRef(5), .geometry))
    }
}

@Suite struct SaveabilityTests {
    @Test func signatureFieldsAreFoundThroughKidsWithInheritedType() {
        // /FT /Sig sits on the parent; the kid widget holds the value.
        var pdf = TestPDF()
        pdf.obj(1, "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [5 0 R] >> >>")
        pdf.obj(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        pdf.obj(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Annots [6 0 R] >>")
        pdf.obj(5, "<< /FT /Sig /T (sig) /Kids [6 0 R] >>")
        pdf.obj(6, "<< /Type /Annot /Subtype /Widget /Parent 5 0 R /Rect [0 0 9 9] /V 7 0 R >>")
        pdf.obj(7, "<< /Type /Sig /Filter /Adobe.PPKLite /Contents <00> /ByteRange [0 1 2 3] >>")
        #expect(Saveability.evaluate(pdf.finishTable(trailer: "/Size 8 /Root 1 0 R")) == .copyOnly([.signed]))
    }

    @Test func emptySignatureFieldOrSigFlagsAloneIsNotSigned() {
        var pdf = TestPDF()
        pdf.obj(1, "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [5 0 R] /SigFlags 3 >> >>")
        pdf.obj(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        pdf.obj(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Annots [5 0 R] >>")
        pdf.obj(5, "<< /FT /Sig /T (empty) /Type /Annot /Subtype /Widget /Rect [0 0 9 9] >>")
        let data = pdf.finishTable(trailer: "/Size 6 /Root 1 0 R")
        #expect(Saveability.evaluate(data) == .inPlace)
        #expect(throws: Never.self) { try IncrementalWriter().saveInPlace(original: data, changes: [.testNote]) }
    }

    @Test func permsAreCopyOnly() {
        func file(_ perms: String) -> Data {
            var pdf = TestPDF()
            pdf.obj(1, "<< /Type /Catalog /Pages 2 0 R /Perms << \(perms) >> >>")
            pdf.obj(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
            pdf.obj(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>")
            pdf.obj(5, "<< /Type /Sig >>")
            return pdf.finishTable(trailer: "/Size 6 /Root 1 0 R")
        }
        #expect(Saveability.evaluate(file("/UR3 5 0 R")) == .copyOnly([.readerExtended]))
        #expect(Saveability.evaluate(file("/UR 5 0 R")) == .copyOnly([.readerExtended]))
        #expect(Saveability.evaluate(file("/DocMDP 5 0 R")) == .copyOnly([.certified]))
        #expect(Saveability.evaluate(file("/DocMDP 5 0 R"), readOnlyLocation: true) == .copyOnly([.certified, .readOnlyLocation]))
        #expect(throws: PDFSaveError.copyOnly([.certified])) {
            try IncrementalWriter().saveInPlace(original: file("/DocMDP 5 0 R"), changes: [.testNote])
        }
        #expect(throws: Never.self) { try IncrementalWriter().saveCopy(original: file("/DocMDP 5 0 R"), changes: [.testNote]) }
    }

    @Test func unsupportedFiles() {
        #expect(Saveability.evaluate(WriterUnitTests.minimalPDF(trailerExtra: "/Encrypt << /Filter /Standard >> "))
            == .unsupported(.encrypted))
        #expect(Saveability.evaluate(WriterUnitTests.minimalPDF(corruptOffset: true))
            == .unsupported(.malformed("expected integer at offset 114")))
        #expect(Saveability.evaluate(Data("junk".utf8) + WriterUnitTests.minimalPDF())
            == .unsupported(.unsupportedStructure("data before the %PDF- header")))
        #expect(Saveability.evaluate(Data()) == .unsupported(.malformed("no %PDF- header")))
        // A page whose /Annots doesn't resolve fails the structural pass, not the later save.
        #expect(Saveability.evaluate(page1("/Annots 5 0 R ", objects: [(5, "(not an array)")]))
            == .unsupported(.malformed("/Annots of page 3 0 R is not an array")))
        // The location alone never overrides an unsupported file.
        #expect(Saveability.evaluate(Data(), readOnlyLocation: true) == .unsupported(.malformed("no %PDF- header")))
    }
}

import Foundation
import Testing
@testable import PDFSave

private let quad = Quad(rect: PDFRect(x: 20, y: 100, width: 120, height: 12))

private func page1(objects: [(Int, String)] = [], annots: String = "") -> Data {
    var pdf = TestPDF.pages(1, pageExtra: [0: annots])
    for (n, body) in objects { pdf.obj(n, body) }
    return pdf.finishTable(trailer: "/Size \((objects.map(\.0).max() ?? 3) + 1) /Root 1 0 R")
}

/// The ordered change list behind ⌘S (A1, M4b).
@Suite struct PendingChangesTests {
    let highlight = NewMarkup(kind: .highlight, pageIndex: 0, quads: [quad], name: "lectern-a")
    let note = NewNote(pageIndex: 0, origin: PDFPoint(x: 10, y: 10), contents: "n", name: "lectern-b")

    @Test func editsOfAnUnsavedAnnotationFoldIntoItsAdd() throws {
        var list = PendingChanges()
        try list.add(.addMarkup(highlight))
        try list.add(.addNote(note))
        let colored = list.setColor(PDFRGBColor(red: 0, green: 1, blue: 0), ofAddNamed: "lectern-a")
        let commented = list.setContents("comment", ofAddNamed: "lectern-a")
        let cleared = list.setContents(nil, ofAddNamed: "lectern-b")
        #expect(colored && commented && cleared)
        var expected = highlight
        expected.color = PDFRGBColor(red: 0, green: 1, blue: 0)
        expected.contents = "comment"
        var expectedNote = note
        expectedNote.contents = nil
        #expect(list.changes == [.addMarkup(expected), .addNote(expectedNote)])
        #expect(list.addedNames == ["lectern-a", "lectern-b"])
    }

    @Test func deletingAnUnsavedAnnotationRemovesItsAdd() throws {
        var list = PendingChanges()
        try list.add(.addMarkup(highlight))
        let removed = list.removeAdd(named: "lectern-a")
        #expect(removed == .addMarkup(highlight))
        #expect(list.isEmpty)
        let again = list.removeAdd(named: "lectern-a")
        let colored = list.setColor(.yellow, ofAddNamed: "lectern-a")
        #expect(again == nil && !colored)
    }

    @Test func aDuplicateNameIsRefused() throws {
        var list = PendingChanges()
        try list.add(.addMarkup(highlight))
        #expect(throws: PDFSaveError.duplicateName("lectern-a")) { try list.add(.addMarkup(highlight)) }
        #expect(throws: PDFSaveError.self) { try list.add(.delete(ObjectRef(5))) }
    }

    @Test func editsOfExistingObjectsReplaceEarlierEditsInPlace() {
        var list = PendingChanges()
        let a = ObjectRef(5), b = ObjectRef(6)
        list.editColor(a, .yellow)
        list.editContents(b, "x")
        list.editColor(a, PDFRGBColor(red: 1, green: 0, blue: 0))
        list.editContents(b, nil)
        list.delete(a)
        list.delete(a)
        #expect(list.changes == [.editColor(a, PDFRGBColor(red: 1, green: 0, blue: 0)), .editContents(b, nil), .delete(a)])
        #expect(list.hasPendingDelete(of: a))
        let cancelled = list.cancelDelete(of: a)
        let cancelledAgain = list.cancelDelete(of: a)
        #expect(cancelled && !cancelledAgain)
        #expect(list.changes == [.editColor(a, PDFRGBColor(red: 1, green: 0, blue: 0)), .editContents(b, nil)])
    }

    @Test func roundTripsThroughJSON() throws {
        var list = PendingChanges()
        try list.add(.addMarkup(highlight))
        list.delete(ObjectRef(9, 1))
        let decoded = try JSONDecoder().decode(PendingChanges.self, from: JSONEncoder().encode(list))
        #expect(decoded == list)
    }

    @Test func theFoldedListIsWhatTheWriterSaves() throws {
        let original = page1(objects: [(4, "<< /Type /Annot /Subtype /Square /Rect [10 10 50 50] /Contents (old) >>")], annots: "/Annots [4 0 R]")
        var list = PendingChanges()
        try list.add(.addMarkup(highlight))
        try list.add(.addNote(note))
        list.setColor(PDFRGBColor(red: 0, green: 0, blue: 1), ofAddNamed: "lectern-a")
        list.removeAdd(named: "lectern-b")
        list.editContents(ObjectRef(4), "new")
        let result = try IncrementalWriter().saveInPlace(original: original, changes: list.changes)
        let descriptors = try PDFSaveDocument(data: result.data).annotations()
        #expect(descriptors.map(\.subtype) == ["Square", "Highlight"])
        #expect(descriptors[0].contents == "new")
        #expect(descriptors[1].color == .rgb(PDFRGBColor(red: 0, green: 0, blue: 1)))
        try SavedFileCheck.verify(result.data, original: original, against: result)
    }
}

/// The re-read after a save has written its file (A1).
@Suite struct SavedFileCheckTests {
    let original = page1(objects: [
        (4, "<< /Type /Annot /Subtype /Text /Rect [10 10 30 30] /Popup 5 0 R >>"),
        (5, "<< /Type /Annot /Subtype /Popup /Rect [40 40 90 90] /Parent 4 0 R >>"),
    ], annots: "/Annots [4 0 R 5 0 R]")

    func save() throws -> SaveResult {
        try IncrementalWriter().saveInPlace(original: original, changes: [
            .addMarkup(NewMarkup(kind: .underline, pageIndex: 0, quads: [quad], name: "lectern-u")),
            .delete(ObjectRef(4)),
        ])
    }

    @Test func acceptsTheBytesTheWriterProduced() throws {
        let result = try save()
        #expect(result.removedAnnotations.count == 2)
        try SavedFileCheck.verify(result.data, original: original, against: result)
    }

    @Test func refusesDifferentBytes() throws {
        let result = try save()
        var damaged = result.data
        damaged[damaged.count - 3] ^= 0x20
        #expect(throws: PDFSaveError.self) { try SavedFileCheck.verify(damaged, original: original, against: result) }
        #expect(throws: PDFSaveError.self) { try SavedFileCheck.verify(result.data.prefix(result.data.count - 10), original: original, against: result) }
    }

    @Test func refusesAnOriginalThatIsNotThePrefix() throws {
        let result = try save()
        var other = original
        other[20] ^= 0x01
        #expect(throws: PDFSaveError.self) { try SavedFileCheck.verify(result.data, original: other, against: result) }
    }
    // MARK: Net changes (M7 review, D3)

    @Test func anEditFollowedByADeleteIsJustTheDelete() {
        var list = PendingChanges()
        let saved = ObjectRef(11)
        list.editContents(saved, nil)
        list.editColor(saved, .yellow)
        list.editContents(ObjectRef(12), "kept")
        list.delete(saved)
        #expect(list.changes.count == 4)
        #expect(list.netChanges == [.editContents(ObjectRef(12), "kept"), .delete(saved)])
        // The list itself, which undo works on, is unchanged.
        #expect(list.changes.count == 4)
    }

    @Test func withoutADeleteNothingIsDropped() throws {
        var list = PendingChanges()
        list.editContents(ObjectRef(11), "a")
        try list.add(.addNote(NewNote(pageIndex: 0, origin: PDFPoint(x: 1, y: 1), contents: "b", name: "lectern-n")))
        #expect(list.netChanges == list.changes)
    }
}

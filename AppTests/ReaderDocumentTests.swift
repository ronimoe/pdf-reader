import AppKit
import PDFKit
import ReaderCore
import Testing
@testable import Lectern

@Suite(.noUI) struct ReaderDocumentTests {
    @Test func readsPDFAndKeepsOriginalBytes() throws {
        let data = try #require(TestPDF.make(pageCount: 3))
        let document = try ReaderDocument.loaded(data)
        #expect(document.originalData == data)
        #expect(document.pdfDocument?.pageCount == 3)
    }

    @Test func rejectsNonPDF() {
        let document = ReaderDocument()
        #expect(throws: (any Error).self) {
            try document.read(from: Data("not a pdf".utf8), ofType: "com.adobe.pdf")
        }
    }

    @Test func neverAutosaves() {
        #expect(ReaderDocument.autosavesInPlace == false)
        #expect(ReaderDocument.autosavesDrafts == false)
        #expect(ReaderDocument.preservesVersions == false)
    }

    @Test func savesPDFButNeverAutosaves() {
        let document = ReaderDocument()
        #expect(document.writableTypes(for: .saveOperation) == ["com.adobe.pdf"])
        #expect(document.writableTypes(for: .saveAsOperation) == ["com.adobe.pdf"])
        #expect(document.writableTypes(for: .saveToOperation) == ["com.adobe.pdf"])
        #expect(document.writableTypes(for: .autosaveInPlaceOperation).isEmpty)
        #expect(document.writableTypes(for: .autosaveElsewhereOperation).isEmpty)
        #expect(document.writableTypes(for: .autosaveAsOperation).isEmpty)
        #expect(!document.hasUnautosavedChanges)
    }

    // MARK: Rotation (B9)

    @Test func recordsEachPagesOriginalRotation() throws {
        let document = try ReaderDocument.loaded(RawPDF.make(pageRotations: [0, 90, 270]))
        #expect(document.originalPageRotations == [0, 90, 270])
        #expect(document.originalRotation(ofPageAt: 1) == 90)
        #expect(document.originalRotation(ofPageAt: 3) == nil)
        #expect(document.originalRotation(ofPageAt: -1) == nil)
    }

    @Test func viewRotationIsAppliedOnTopOfTheOriginal() throws {
        let document = try ReaderDocument.loaded(RawPDF.make(pageRotations: [0, 90, 270]))
        document.applyViewRotation(90)
        #expect(pageRotations(document) == [90, 180, 0])
        document.applyViewRotation(0)
        #expect(pageRotations(document) == [0, 90, 270])
        #expect(document.originalPageRotations == [0, 90, 270])
    }

    @Test func rotatingNeverChangesOriginalData() throws {
        let data = RawPDF.make(pageRotations: [0, 90])
        let document = try ReaderDocument.loaded(data)
        for degrees in [90, 180, 270, 90] {
            document.applyViewRotation(degrees)
            #expect(document.originalData == data)
        }
        // The bytes still describe the unrotated pages.
        let reopened = try #require(PDFDocument(data: document.originalData))
        #expect(reopened.page(at: 0)?.rotation == 0)
        #expect(reopened.page(at: 1)?.rotation == 90)
    }

    // MARK: Hints, key and passwords

    @Test func readsLayoutHintsFromTheCatalog() throws {
        let document = try ReaderDocument.loaded(RawPDF.make(
            catalogExtras: "/PageLayout /TwoColumnRight /ViewerPreferences << /Direction /R2L >>"
        ))
        #expect(document.layoutHints == DocumentLayoutHints(coverPageAlone: true, rightToLeft: true))
    }

    @Test func lockedDocumentWaitsForItsPassword() throws {
        let data = try #require(TestPDF.encrypted(user: "user", owner: "owner"))
        let document = try ReaderDocument.loaded(data)
        #expect(document.isPasswordLocked)
        #expect(document.originalPageRotations.isEmpty)
        // The key comes from the unencrypted trailer, so it is there before unlocking.
        #expect(document.documentKey.rawValue.hasPrefix("id:"))

        #expect(!document.unlock(withPassword: "wrong"))
        #expect(document.isPasswordLocked)
        #expect(document.unlock(withPassword: "user"))
        #expect(!document.isPasswordLocked)
        #expect(document.originalPageRotations == [0, 0])
        #expect(!document.hasOwnerAccess)
        // Once open, only the owner password counts as gaining access.
        #expect(!document.unlock(withPassword: "anything"))
        #expect(!document.unlock(withPassword: "user"))
        #expect(document.unlock(withPassword: "owner"))
    }

    @Test func wrongOwnerPasswordOnAnOpenDocumentIsAFailure() throws {
        let document = try ReaderDocument.loaded(try #require(TestPDF.encrypted(user: nil, owner: "owner")))
        #expect(!document.unlock(withPassword: "stale"))
        #expect(!document.hasOwnerAccess)
    }

    @Test func ownerPasswordLiftsRestrictions() throws {
        let data = try #require(TestPDF.encrypted(user: nil, owner: "owner"))
        let document = try ReaderDocument.loaded(data)
        #expect(!document.isPasswordLocked)
        #expect(!document.allowsCopying)
        #expect(!document.allowsPrinting)
        #expect(document.unlock(withPassword: "owner"))
        #expect(document.hasOwnerAccess)
        #expect(document.allowsCopying)
        #expect(document.allowsPrinting)
    }

    // MARK: Printing

    @Test func printOperationUsesPDFKit() throws {
        let document = try ReaderDocument.loaded(try #require(TestPDF.make(pageCount: 2)))
        let operation = try document.printOperation(withSettings: [:])
        #expect(operation.jobTitle == document.displayName)
    }

    @Test func printOperationIsRefusedWhenPrintingIsRestricted() throws {
        let document = try ReaderDocument.loaded(try #require(TestPDF.encrypted(user: nil, owner: "owner", allowsCopying: true)))
        #expect(throws: CocoaError.self) { try document.printOperation(withSettings: [:]) }
        document.unlock(withPassword: "owner")
        #expect(throws: Never.self) { try document.printOperation(withSettings: [:]) }
    }

    @Test func printStaysEnabledForRestrictedDocumentsSoItCanExplain() throws {
        let item = NSMenuItem(title: "Print…", action: #selector(NSDocument.printDocument(_:)), keyEquivalent: "p")
        let restricted = try ReaderDocument.loaded(try #require(TestPDF.encrypted(user: nil, owner: "owner")))
        #expect(restricted.validateUserInterfaceItem(item))
        let locked = try ReaderDocument.loaded(try #require(TestPDF.encrypted(user: "user", owner: "owner")))
        #expect(!locked.validateUserInterfaceItem(item))
    }

    private func pageRotations(_ document: ReaderDocument) -> [Int] {
        let pdf = document.pdfDocument!
        return (0..<pdf.pageCount).map { pdf.page(at: $0)!.rotation }
    }
}

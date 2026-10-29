import AppKit
import PDFKit
import Persistence
import ReaderCore
import ReaderKit
import Testing
@testable import Lectern

@MainActor
@Suite(.serialized) struct LifecycleTests {
    @Test func quittingWritesEveryOpenDocumentsPosition() throws {
        // The shared store, as the app uses it (a throwaway folder in tests).
        let store = try #require(AppEnvironment.stateStore)
        let folder = try TemporaryFolder()
        let file = try folder.write(FixturePDF.prose(pages: 10, id: "0F0E0D"), to: "quit.pdf")
        let harness = try NavigationHarness(file: file, store: store)
        defer { harness.close() }
        NSDocumentController.shared.addDocument(harness.document)
        let id = try #require(harness.controller.storedDocumentID)
        harness.read(at: 6)

        let delegate = try #require(NSApp.delegate as? AppDelegate)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        // A fresh store reads only what reached the disk.
        let written = DocumentStateStore(directory: store.directory).state(for: id)
        #expect(written?.anchor?.pageIndex == 6)
    }

    @Test func clearingRecentDocumentsForgetsTheirState() throws {
        let folder = try TemporaryFolder()
        let store = folder.store()
        let file = try folder.write(FixturePDF.prose(pages: 6, id: "0C0C"), to: "recent.pdf")
        let other = try folder.write(FixturePDF.prose(pages: 6, id: "0D0D"), to: "kept.pdf")
        let harness = try NavigationHarness(file: file, store: store)
        let id = try #require(harness.controller.storedDocumentID)
        harness.read(at: 4)
        harness.close()
        let keptHarness = try NavigationHarness(file: other, store: store)
        let keptID = try #require(keptHarness.controller.storedDocumentID)
        keptHarness.close()

        ReaderDocumentController.forgetStoredState(for: [file], in: store)
        #expect(store.storedDocumentIDs == [keptID])
        let reread = DocumentStateStore(directory: store.directory)
        #expect(reread.state(for: id) == nil)
        #expect(reread.storedDocumentIDs == [keptID])
        // The menu command goes through it.
        let selector = #selector(NSDocumentController.clearRecentDocuments(_:))
        #expect(ReaderDocumentController.instanceMethod(for: selector) != NSDocumentController.instanceMethod(for: selector))
    }

    @Test func theTestHostsStateFolderIsRegisteredForRemoval() throws {
        let directory = try #require(AppEnvironment.stateStore?.directory)
        #expect(AppEnvironment.testStateFolder == directory)
        #expect(directory.lastPathComponent.hasPrefix(AppEnvironment.testFolderPrefix))
    }
}

@MainActor
@Suite struct TrashTests {
    @Test func aTrashOnAnyVolumeCounts() {
        #expect(ReaderDocument.isInTrash(URL(fileURLWithPath: "/Volumes/Backup/.Trashes/501/paper.pdf")))
        #expect(ReaderDocument.isInTrash(URL(fileURLWithPath: "/Users/someone/.Trash/paper.pdf")))
        #expect(!ReaderDocument.isInTrash(URL(fileURLWithPath: "/Users/someone/Documents/paper.pdf")))
        #expect(!ReaderDocument.isInTrash(URL(fileURLWithPath: "/Volumes/Backup/Trashes and treasures/paper.pdf")))
    }

    @Test func movingToAnotherVolumesTrashCountsAsRemoved() async throws {
        let harness = try NavigationHarness(FixturePDF.prose(pages: 2))
        defer { harness.close() }
        harness.document.presentedItemDidMove(to: URL(fileURLWithPath: "/Volumes/Backup/.Trashes/501/paper.pdf"))
        await eventually { harness.document.fileWasRemoved }
        #expect(harness.document.fileWasRemoved)
    }
}

@MainActor
@Suite struct TextInventoryRaceTests {
    @Test func aStaleTextCheckNeverOverwritesTheReloadedDocument() async throws {
        // A long document's check is still running when the file reloads as
        // a short scanned one, whose check finishes first.
        let harness = try NavigationHarness(FixturePDF.prose(pages: 400))
        defer { harness.close() }
        harness.controller.startSearch("Page")
        let old = try #require(harness.controller.textInventory)
        let scanned = FixturePDF.make(pageTexts: [nil, nil, nil])
        harness.document.reload(with: scanned, pdf: try #require(PDFDocument(data: scanned)))
        #expect(harness.controller.textInventory !== old)

        await harness.controller.waitForTextInventory()
        #expect(harness.controller.pagesWithoutText == [0, 1, 2])
        // Let the old check run to the end as well.
        _ = await old.pagesWithoutText()
        try await Task.sleep(for: .milliseconds(200))
        #expect(harness.controller.pagesWithoutText == [0, 1, 2])
        #expect(harness.controller.search?.summary.documentHasNoText == true)
    }
}

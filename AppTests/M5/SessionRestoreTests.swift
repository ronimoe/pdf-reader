import AppKit
import Persistence
import ReaderCore
import ReaderKit
import Testing
@testable import Lectern

/// A store whose Keychain read fails, as a declined or denied prompt does after an update (B6).
nonisolated final class FailingPasswordStore: DocumentPasswordStore {
    struct Denied: Error {}
    func password(for key: DocumentKey) throws -> String? { throw Denied() }
    func setPassword(_ password: String, for key: DocumentKey) throws {}
    func removePassword(for key: DocumentKey) throws {}
}

extension M5Tests {
    @MainActor
    @Suite struct SessionRestoreTests {
        private var controller: ReaderDocumentController { NSDocumentController.shared as! ReaderDocumentController }

        private func restorer(_ folder: TemporaryFolder, policy: SessionRestorePolicy = .always, keeps: Bool = false) -> SessionRestorer {
            let restorer = SessionRestorer(fileURL: folder.url.appending(path: "Session.json"), policy: { policy }, systemKeepsWindows: { keeps })
            restorer.prepareWindow = { M5Harness.prepareInvisible($0) }
            return restorer
        }

        private func open(_ url: URL) async throws -> ReaderDocument {
            let (document, _) = try await controller.openDocument(withContentsOf: url, display: false)
            document.makeWindowControllers()
            let reader = try #require(document as? ReaderDocument)
            let window = try #require(reader.readerWindowController?.window)
            M5Harness.makeInvisible(window)
            return reader
        }

        private func closeAll(_ documents: [NSDocument]) {
            for document in documents {
                document.windowControllers.forEach { $0.window?.orderOut(nil) }
                document.close()
            }
        }

        @Test func thePolicyFollowsMacOSUnlessSetOtherwise() {
            #expect(SessionRestorePolicy.system.shouldRestore(systemKeepsWindows: true))
            #expect(!SessionRestorePolicy.system.shouldRestore(systemKeepsWindows: false))
            #expect(SessionRestorePolicy.always.shouldRestore(systemKeepsWindows: false))
            #expect(!SessionRestorePolicy.never.shouldRestore(systemKeepsWindows: true))
        }

        @Test func captureGroupsTabsIntoWindowsFrontToBack() async throws {
            controller.recordsRecentDocuments = false
            defer { controller.recordsRecentDocuments = true }
            let folder = try TemporaryFolder()
            let a = try await open(try folder.write(TestPDF.make(pageCount: 2)!, to: "A.pdf"))
            let b = try await open(try folder.write(TestPDF.make(pageCount: 2)!, to: "B.pdf"))
            let c = try await open(try folder.write(TestPDF.make(pageCount: 2)!, to: "C.pdf"))
            defer { closeAll([a, b, c]) }
            let wa = try #require(a.readerWindowController?.window)
            let wb = try #require(b.readerWindowController?.window)
            let wc = try #require(c.readerWindowController?.window)
            wa.addTabbedWindow(wb, ordered: .above)
            wa.tabGroup?.selectedWindow = wb
            c.readerWindowController?.setDistractionFree(true)

            let controllers = [a, b, c].compactMap(\.readerWindowController)
            let state = SessionRestorer.capture(controllers, orderedWindows: [wc, wb, wa])
            #expect(state.windows.count == 2)
            #expect(state.windows.first?.tabs.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["C.pdf"])
            #expect(state.windows.first?.tabs.first?.distractionFree == true)
            let tabs = try #require(state.windows.last)
            #expect(tabs.tabs.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["A.pdf", "B.pdf"])
            #expect(tabs.selectedTab == 1)
            #expect(tabs.tabs.allSatisfy { $0.bookmark != nil })
        }

        @Test func restoreReopensWindowsTabsAndPlacesAndSkipsMissingFilesQuietly() async throws {
            controller.recordsRecentDocuments = false
            defer { controller.recordsRecentDocuments = true }
            let folder = try TemporaryFolder()
            let urlA = try folder.write(TestPDF.make(pageCount: 6)!, to: "Restored A.pdf")
            let urlB = try folder.write(TestPDF.make(pageCount: 6)!, to: "Restored B.pdf")
            let missing = folder.url.appending(path: "Gone.pdf")

            // Last session: A split and on page 5, B in distraction-free mode, a file since deleted.
            let first = try await open(urlA)
            let firstController = try #require(first.readerWindowController)
            firstController.primaryPane.view.restore(try #require(firstController.primaryPane.view.topAnchor(forPageAt: 4)))
            firstController.openSplit(at: firstController.primaryPane.view.topAnchor(forPageAt: 1))
            firstController.saveStateNow()
            closeAll([first])

            func tab(_ url: URL, _ free: Bool = false) -> SessionState.Tab {
                .init(bookmark: try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil), path: url.path, distractionFree: free)
            }
            let frame = NSRect(x: 40, y: 60, width: 700, height: 640)
            let restorer = restorer(folder)
            restorer.save(SessionState(windows: [
                .init(frame: NSStringFromRect(frame), tabs: [tab(urlA), .init(bookmark: nil, path: missing.path, distractionFree: false), tab(urlB, true)], selectedTab: 2),
            ]))

            let blockedBefore = UITripwire.shared.calls.count
            let reopened = await restorer.restore()
            defer { closeAll(reopened) }
            #expect(UITripwire.shared.calls.count == blockedBefore, "a missing file shows no error")
            #expect(reopened.compactMap { $0.fileURL?.lastPathComponent } == ["Restored A.pdf", "Restored B.pdf"])

            let a = try #require((reopened.first as? ReaderDocument)?.readerWindowController)
            let b = try #require((reopened.last as? ReaderDocument)?.readerWindowController)
            let windowA = try #require(a.window)
            let windowB = try #require(b.window)
            #expect(windowA.tabGroup === windowB.tabGroup, "one window with two tabs")
            #expect(windowA.tabGroup?.windows == [windowA, windowB])
            #expect(windowA.tabGroup?.selectedWindow === windowB)
            #expect(windowA.frame.size == frame.size)
            #expect(b.isDistractionFree)
            #expect(!a.isDistractionFree)
            // Each pane's place comes back from the document's stored state (A2).
            #expect(a.isSplit)
            #expect(a.primaryPane.view.currentAnchor?.pageIndex == 4)
            #expect(a.secondaryPane?.view.currentAnchor?.pageIndex == 1)
        }

        @Test func nothingIsRestoredWhenThePolicySaysNo() async throws {
            let folder = try TemporaryFolder()
            let url = try folder.write(TestPDF.make(pageCount: 2)!, to: "Not Restored.pdf")
            let state = SessionState(windows: [.init(frame: NSStringFromRect(.init(x: 0, y: 0, width: 500, height: 500)), tabs: [.init(bookmark: nil, path: url.path, distractionFree: false)], selectedTab: 0)])
            let system = restorer(folder, policy: .system, keeps: false)
            system.save(state)
            #expect(await system.restore().isEmpty, "macOS closes windows on quit, so nothing comes back")
            #expect(!controller.documents.contains { $0.fileURL?.lastPathComponent == "Not Restored.pdf" })

            let never = restorer(folder, policy: .never, keeps: true)
            never.save(state)
            #expect(never.load() == nil, "Never keeps no list of open files")
            #expect(await never.restore().isEmpty)
        }

        @Test func savingAndLoadingRoundTrips() throws {
            let folder = try TemporaryFolder()
            let r = restorer(folder)
            let state = SessionState(windows: [.init(frame: "{{1, 2}, {3, 4}}", tabs: [.init(bookmark: Data([1, 2]), path: "/x.pdf", distractionFree: true)], selectedTab: 0)])
            r.save(state)
            #expect(r.load() == state)
            r.save(.empty)
            #expect(r.load() == nil)
        }

        @Test func aDocumentAlreadyOpenIsNotOpenedTwice() async throws {
            controller.recordsRecentDocuments = false
            defer { controller.recordsRecentDocuments = true }
            let folder = try TemporaryFolder()
            let url = try folder.write(TestPDF.make(pageCount: 2)!, to: "Open Already.pdf")
            let document = try await open(url)
            defer { closeAll([document]) }
            let r = restorer(folder)
            r.save(SessionState(windows: [.init(frame: "{{0, 0}, {500, 500}}", tabs: [.init(bookmark: nil, path: url.path, distractionFree: false)], selectedTab: 0)]))
            #expect(await r.restore().isEmpty)
            #expect(controller.documents.filter { $0.fileURL?.lastPathComponent == "Open Already.pdf" }.count == 1)
        }

        @Test func readerWindowsAreNotRestoredByAppKitToo() throws {
            let h = try M5Harness(TestPDF.make(pageCount: 1)!)
            defer { h.close() }
            #expect(!h.window.isRestorable)
        }

        @Test func anEncryptedDocumentAsksAgainWhenTheKeychainReadFails() throws {
            let data = try #require(TestPDF.encrypted(user: "user", owner: "owner"))
            let document = try ReaderDocument.loaded(data)
            let presenter = RecordingPresenter()
            let controller = ReaderWindowController(document: document, passwordStore: FailingPasswordStore(), presenter: presenter, stateStore: nil)
            document.addWindowController(controller)
            defer { document.close() }
            M5Harness.makeInvisible(try #require(controller.window))
            controller.checkPasswordsIfNeeded()
            #expect(presenter.prompts.count == 1, "a failed or declined read counts as not remembered (B6)")
            #expect(!controller.isShowingContent)
        }
    }
}

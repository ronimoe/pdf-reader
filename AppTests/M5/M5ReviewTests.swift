import AppKit
import Persistence
import ReaderCore
import ReaderKit
import Testing
@testable import Lectern

/// M5 review (PR #13): one test per finding, each failing without its fix.
extension M5Tests {
    @MainActor
    @Suite struct M5ReviewTests {
        private var controller: ReaderDocumentController { NSDocumentController.shared as! ReaderDocumentController }

        private func restorer(_ folder: TemporaryFolder, policy: SessionRestorePolicy = .always, keeps: Bool = false) -> SessionRestorer {
            let restorer = SessionRestorer(fileURL: folder.url.appending(path: "Session.json"), policy: { policy }, systemKeepsWindows: { keeps })
            restorer.prepareWindow = { M5Harness.prepareInvisible($0) }
            restorer.ignoresPersistentState = { false }
            restorer.currentControllers = { [] }
            return restorer
        }

        private func session(_ tabs: [SessionState.Tab], frame: String = "{{40, 60}, {700, 640}}", selected: Int = 0) -> SessionState {
            SessionState(windows: [.init(frame: frame, tabs: tabs, selectedTab: selected)])
        }

        private func tab(_ url: URL, bookmark: Bool = true) -> SessionState.Tab {
            .init(bookmark: bookmark ? try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) : nil,
                  path: url.path, distractionFree: false)
        }

        private func closeAll(_ documents: [NSDocument]) {
            for document in documents {
                document.windowControllers.forEach { $0.window?.orderOut(nil) }
                document.close()
            }
        }

        // MARK: 1. Only the launch arguments count

        @Test func onlyTheArgumentDomainMakesATestLaunch() {
            #expect(SessionRestorer.argumentFlag("ApplePersistenceIgnoreState", in: ["ApplePersistenceIgnoreState": "YES"]))
            #expect(SessionRestorer.argumentFlag("K", in: ["K": true]))
            #expect(!SessionRestorer.argumentFlag("K", in: ["K": "NO"]))
            #expect(!SessionRestorer.argumentFlag("K", in: [:]))
            // A value in another domain (here the registration domain, which UserDefaults reads
            // like the app or global domain) doesn't count.
            let key = "LecternReviewProbe-\(UUID().uuidString)"
            UserDefaults.standard.register(defaults: [key: true])
            #expect(UserDefaults.standard.bool(forKey: key), "visible through the usual lookup")
            #expect(!SessionRestorer.argumentFlag(key, in: UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)))
            // The test host is launched with -ApplePersistenceIgnoreState YES, on the command line.
            #expect(SessionRestorer.launchIgnoresPersistentState())
            #expect(AppDelegate.asksAboutUpdatesAtLaunch(hostingTests: false, ignoresState: false))
            #expect(!AppDelegate.asksAboutUpdatesAtLaunch(hostingTests: false, ignoresState: true))
        }

        // MARK: 2 and 4. Quits: cancelled, and during a restore

        @Test func aCancelledQuitKeepsSavingAndAQuitWithoutReviewStillSaves() throws {
            let folder = try TemporaryFolder()
            let r = restorer(folder)
            let h = try M5Harness(file: try folder.write(TestPDF.make(pageCount: 2)!, to: "Open.pdf"), store: nil)
            defer { h.close() }
            r.currentControllers = { [h.controller] }
            let coordinator = SessionCoordinator(restorer: r, emptyStateDidChange: { _ in }, showEmptyState: {}, hideEmptyState: {}, documentCount: { 1 }, anyWindowVisible: { true })

            coordinator.willReviewForQuit()
            #expect(r.isTerminating)
            coordinator.reviewEnded(didReviewAll: false)
            #expect(!r.isTerminating, "the user cancelled: saving carries on")
            try FileManager.default.removeItem(at: r.fileURL)
            coordinator.documentsDidChange(count: 1)
            #expect(r.load()?.windows.count == 1)

            // A later quit that doesn't go through the review still saves.
            try FileManager.default.removeItem(at: r.fileURL)
            coordinator.willTerminate()
            #expect(r.load()?.windows.count == 1)
            #expect(r.isTerminating)
        }

        @Test func theReviewForwarderReportsHowItEndedAndPassesItOn() {
            final class Recorder: NSObject {
                var answers: [(Bool, UnsafeMutableRawPointer?)] = []
                @objc func reviewed(_ controller: NSDocumentController, didReviewAll: Bool, contextInfo: UnsafeMutableRawPointer?) {
                    answers.append((didReviewAll, contextInfo))
                }
            }
            let recorder = Recorder()
            var ended: [Bool] = []
            let forwarder = ReviewForwarder(delegate: recorder, selector: #selector(Recorder.reviewed(_:didReviewAll:contextInfo:))) { ended.append($0) }
            let context = UnsafeMutableRawPointer(bitPattern: 0x1234)
            forwarder.documentController(controller, didReviewAll: false, contextInfo: context)
            forwarder.documentController(controller, didReviewAll: true, contextInfo: nil)
            #expect(ended == [false, true])
            #expect(recorder.answers.map(\.0) == [false, true])
            #expect(recorder.answers.first?.1 == context)
        }

        @Test func theDocumentControllerReportsTheEndOfItsReview() {
            var events: [String] = []
            let saved = (controller.onWillReviewForQuit, controller.onReviewEnded)
            defer { (controller.onWillReviewForQuit, controller.onReviewEnded) = saved }
            controller.onWillReviewForQuit = { events.append("will") }
            controller.onReviewEnded = { events.append("ended \($0)") }
            // Nothing is edited, so the review ends at once without asking.
            guard controller.documents.allSatisfy({ !$0.isDocumentEdited }) else { return }
            controller.reviewUnsavedDocuments(withAlertTitle: nil, cancellable: true, delegate: nil, didReviewAllSelector: nil, contextInfo: nil)
            spin(timeout: 1) { events.count == 2 }
            #expect(events == ["will", "ended true"])
        }

        @Test func aQuitDuringTheRestoreLeavesTheSessionAlone() throws {
            let folder = try TemporaryFolder()
            let r = restorer(folder)
            let saved = session([tab(try folder.write(TestPDF.make(pageCount: 2)!, to: "Later.pdf"))])
            r.save(saved)
            let coordinator = SessionCoordinator(restorer: r, emptyStateDidChange: { _ in }, showEmptyState: {}, hideEmptyState: {}, documentCount: { 0 }, anyWindowVisible: { false })
            coordinator.beginRestoring()
            coordinator.willReviewForQuit()
            coordinator.willTerminate()
            coordinator.documentsDidChange(count: 0)
            #expect(r.load() == saved, "half a restore never overwrites the session")
            #expect(!r.isTerminating)
        }

        @Test func theEmptyStateWaitsForTheRestore() {
            var shown = 0
            var changes: [Int] = []
            let coordinator = SessionCoordinator(restorer: nil, emptyStateDidChange: { changes.append($0) }, showEmptyState: { shown += 1 }, hideEmptyState: {}, documentCount: { 0 }, anyWindowVisible: { false })
            coordinator.beginRestoring()
            coordinator.openUntitled()
            coordinator.documentsDidChange(count: 0)
            #expect(shown == 0 && changes.isEmpty)
            coordinator.finishRestoring()
            #expect(shown == 1, "nothing came back, so the empty state shows once")
        }

        // MARK: 6. Bookmarks follow moved files; skipped tabs give their access back

        @Test func aMovedFileIsRestoredFromWhereItIsNow() async throws {
            controller.recordsRecentDocuments = false
            defer { controller.recordsRecentDocuments = true }
            let folder = try TemporaryFolder()
            let original = try folder.write(TestPDF.make(pageCount: 2)!, to: "Before Move.pdf")
            let saved = session([tab(original)])
            let moved = folder.url.appending(path: "After Move.pdf")
            try FileManager.default.moveItem(at: original, to: moved)
            let r = restorer(folder)
            r.makeKey = { _ in }
            r.save(saved)
            let reopened = await r.restore()
            defer { closeAll(reopened) }
            #expect(reopened.compactMap { $0.fileURL?.lastPathComponent } == ["After Move.pdf"])
        }

        @Test func skippedTabsGiveTheirAccessBack() async throws {
            controller.recordsRecentDocuments = false
            defer { controller.recordsRecentDocuments = true }
            let folder = try TemporaryFolder()
            let url = try folder.write(TestPDF.make(pageCount: 2)!, to: "Twice.pdf")
            let notPDF = try folder.write(Data("not a pdf".utf8), to: "Broken.pdf")
            let r = restorer(folder)
            r.makeKey = { _ in }
            // The same file twice (de-duplicated), and one that fails to open.
            r.save(session([tab(url), tab(url), tab(notPDF)]))
            let reopened = await r.restore()
            defer { closeAll(reopened) }
            #expect(reopened.count == 1, "one file listed twice comes back once")
            #expect(r.releasedCount == 2)
            #expect(r.heldURLs.count <= 1)
        }

        // MARK: 8. Damaged frames

        @Test func aDamagedOrTinyFrameIsIgnored() async throws {
            #expect(SessionRestorer.usableFrame("") == nil)
            #expect(SessionRestorer.usableFrame("{{0, 0}, {0, 0}}") == nil)
            #expect(SessionRestorer.usableFrame("{{10, 10}, {100, 80}}") == nil)
            #expect(SessionRestorer.usableFrame("{{10, 10}, {700, 500}}") == NSRect(x: 10, y: 10, width: 700, height: 500))

            controller.recordsRecentDocuments = false
            defer { controller.recordsRecentDocuments = true }
            let folder = try TemporaryFolder()
            let r = restorer(folder)
            r.makeKey = { _ in }
            r.save(session([tab(try folder.write(TestPDF.make(pageCount: 2)!, to: "Frame.pdf"))], frame: "garbage"))
            let reopened = await r.restore()
            defer { closeAll(reopened) }
            let window = try #require((reopened.first as? ReaderDocument)?.readerWindowController?.window)
            #expect(window.frame.width >= SessionRestorer.minimumFrameSize.width && window.frame.height >= SessionRestorer.minimumFrameSize.height)
        }

        // MARK: 10. No session file that can't be used

        @Test func noSessionFileWhileMacOSClosesWindowsOnQuit() throws {
            let folder = try TemporaryFolder()
            let state = session([.init(bookmark: nil, path: "/x.pdf", distractionFree: false)])
            let follows = restorer(folder, policy: .system, keeps: false)
            follows.save(state)
            #expect(!FileManager.default.fileExists(atPath: follows.fileURL.path))
            let keeps = restorer(folder, policy: .system, keeps: true)
            keeps.save(state)
            #expect(keeps.load() == state)
            // Switching macOS back to closing windows deletes it at the next save.
            follows.save(state)
            #expect(!FileManager.default.fileExists(atPath: follows.fileURL.path))
        }

        // MARK: 11. One password question at a time

        @Test func aRestoredWindowAsksForItsPasswordOnlyWhenItBecomesKey() throws {
            let data = try #require(TestPDF.encrypted(user: "user", owner: "owner"))
            let document = try ReaderDocument.loaded(data)
            let presenter = RecordingPresenter()
            let reader = ReaderWindowController(document: document, passwordStore: InMemoryPasswordStore(), presenter: presenter, stateStore: nil)
            document.addWindowController(reader)
            defer { document.close() }
            let window = try #require(reader.window)
            M5Harness.prepareInvisible(window)
            reader.defersPasswordCheckUntilKey = true
            reader.showWindow(nil)
            defer { window.orderOut(nil) }
            // Showing the window makes it key only while the test host is the active app (CI),
            // and then it should ask. On a developer's Mac it stays unasked until it becomes key.
            #expect(presenter.prompts.count == (window.isKeyWindow ? 1 : 0), "not on show, unless that made it key")
            reader.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
            #expect(presenter.prompts.count == 1)
            reader.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
            #expect(presenter.prompts.count == 1, "once")
        }

        @Test func aRestoreMakesOnlyTheFrontWindowKeyAndDefersEveryPassword() async throws {
            controller.recordsRecentDocuments = false
            defer { controller.recordsRecentDocuments = true }
            let folder = try TemporaryFolder()
            let a = try folder.write(TestPDF.make(pageCount: 2)!, to: "Back.pdf")
            let b = try folder.write(TestPDF.make(pageCount: 2)!, to: "Front One.pdf")
            let c = try folder.write(TestPDF.make(pageCount: 2)!, to: "Front Two.pdf")
            let r = restorer(folder)
            var keyed: [NSWindow] = []
            r.makeKey = { keyed.append($0) }
            r.save(SessionState(windows: [
                .init(frame: "{{40, 60}, {700, 640}}", tabs: [tab(b), tab(c)], selectedTab: 1),
                .init(frame: "{{80, 60}, {700, 640}}", tabs: [tab(a)], selectedTab: 0),
            ]))
            let reopened = await r.restore()
            defer { closeAll(reopened) }
            let controllers = reopened.compactMap { ($0 as? ReaderDocument)?.readerWindowController }
            #expect(controllers.count == 3)
            #expect(controllers.allSatisfy { $0.defersPasswordCheckUntilKey })
            #expect(keyed.count == 1)
            #expect(keyed.first === controllers.first { ($0.document as? NSDocument)?.fileURL?.lastPathComponent == "Front Two.pdf" }?.window)
        }

        // MARK: 5. A stale automatic-check setting never survives Check Now

        @Test func checkNowTurnsOffAStaleAutomaticCheckWhenTheUserSaidNo() throws {
            let preferences = ReaderPreferences.ephemeral()
            preferences.checksForUpdatesAutomatically = false
            let stale = RecordingUpdater()
            stale.automaticallyChecks = true
            let updates = UpdateController(preferences: preferences, question: RecordingUpdateQuestion()) { stale }
            updates.checkNow()
            #expect(!stale.automaticallyChecks)
            #expect(stale.checks == 1)
        }

        // MARK: 12. The first-launch question

        @Test func theUpdateQuestionDefaultsToNoAndEscapeMeansNo() throws {
            let alert = AlertUpdateQuestion.makeAlert()
            #expect(alert.buttons.map(\.title) == ["Don’t Check", "Check Automatically"])
            #expect(alert.buttons[0].keyEquivalent == "\r", "Return answers Don’t Check")
            #expect(alert.buttons[1].keyEquivalent.isEmpty)
            #expect(!AlertUpdateQuestion.answer(for: .alertFirstButtonReturn))
            #expect(AlertUpdateQuestion.answer(for: .alertSecondButtonReturn))
            let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            let response = try #require(AlertUpdateQuestion.response(forKeyDown: escape))
            #expect(!AlertUpdateQuestion.answer(for: response), "Escape means no")
            let letter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
            #expect(AlertUpdateQuestion.response(forKeyDown: letter) == nil)
        }
    }
}

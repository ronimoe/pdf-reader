import AppKit
import Foundation
import Testing
@testable import Lectern

extension M5Tests {
    @MainActor
    @Suite struct UpdateTests {
        final class Harness {
            let preferences = ReaderPreferences.ephemeral()
            let question = RecordingUpdateQuestion()
            private(set) var created: [RecordingUpdater] = []
            lazy var controller = UpdateController(preferences: preferences, question: question) { [unowned self] in
                let updater = RecordingUpdater()
                created.append(updater)
                return updater
            }
        }

        @Test func firstLaunchAsksOnceAndDecliningCreatesNoUpdater() {
            let h = Harness()
            h.controller.start()
            #expect(h.question.asked == 1)
            #expect(h.created.isEmpty, "no updater (so no network) before the answer")
            h.question.respond(false)
            #expect(h.preferences.checksForUpdatesAutomatically == false)
            #expect(h.created.isEmpty, "declining never creates Sparkle")

            // Next launch: never asked again.
            h.controller.start()
            #expect(h.question.asked == 1)
            #expect(h.created.isEmpty)
        }

        @Test func answeringYesStartsScheduledChecks() throws {
            let h = Harness()
            h.controller.start()
            h.question.respond(true)
            #expect(h.preferences.checksForUpdatesAutomatically == true)
            let updater = try #require(h.created.first)
            #expect(updater.automaticallyChecks)
            #expect(updater.checks == 0, "opting in schedules checks; it doesn't check on the spot")
        }

        @Test func anEarlierYesStartsChecksAtLaunchWithoutAsking() throws {
            let h = Harness()
            h.preferences.checksForUpdatesAutomatically = true
            h.controller.start()
            #expect(h.question.asked == 0)
            #expect(try #require(h.created.first).automaticallyChecks)
        }

        @Test func settingsCanTurnChecksOffAndOn() throws {
            let h = Harness()
            h.preferences.checksForUpdatesAutomatically = true
            h.controller.start()
            h.controller.setAutomaticChecks(false)
            #expect(h.preferences.checksForUpdatesAutomatically == false)
            #expect(h.created.first?.automaticallyChecks == false)
            h.controller.setAutomaticChecks(true)
            #expect(h.created.count == 1)
            #expect(h.created.first?.automaticallyChecks == true)
        }

        @Test func checkNowChecksOnceWithoutTurningOnScheduledChecks() throws {
            let h = Harness()
            h.preferences.checksForUpdatesAutomatically = false
            h.controller.checkNow()
            let updater = try #require(h.created.first)
            #expect(updater.checks == 1)
            #expect(!updater.automaticallyChecks)
            #expect(h.preferences.checksForUpdatesAutomatically == false)
        }

        @Test func theTestHostNeverReachesSparkle() {
            #expect(AppEnvironment.isHostingTests)
            #expect(!(AppEnvironment.updates.updater is SparkleUpdater))
            AppEnvironment.updates.checkNow()
            #expect(AppEnvironment.updates.updater is RecordingUpdater)
        }

        @Test func infoPlistHasTheFeedTheKeyAndNoSparklePrompt() throws {
            let info = try #require(Bundle.main.infoDictionary)
            #expect(info["SUFeedURL"] as? String == "https://github.com/ronimoe/pdf-reader/releases/latest/download/appcast.xml")
            let key = try #require(info["SUPublicEDKey"] as? String)
            #expect(Data(base64Encoded: key)?.count == 32)
            // Lectern asks itself; Sparkle must never show its own permission prompt or update silently.
            #expect(info["SUEnableAutomaticChecks"] as? Bool == false)
            #expect(info["SUAutomaticallyUpdate"] as? Bool == false)
            #expect(info["SUEnableInstallerLauncherService"] as? Bool == true)
            #expect(info["SUEnableSystemProfiling"] == nil || info["SUEnableSystemProfiling"] as? Bool == false)
        }

        @Test func theAppMenuOffersCheckForUpdates() throws {
            let items = allMenuItems(MainMenu.make())
            #expect(items.contains { $0.action == #selector(AppDelegate.checkForUpdates(_:)) })
        }
    }
}

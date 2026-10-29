import AppKit
import Sparkle

/// The updater Lectern drives: Sparkle in the app, a recorder in tests.
protocol SoftwareUpdater: AnyObject {
    /// Scheduled checks, at most once a day (`SUScheduledCheckInterval`).
    var automaticallyChecks: Bool { get set }
    /// A check the user asked for, with Sparkle's own progress and result windows.
    func checkNow()
}

/// Asks the one-time first-launch question (A4). Replaced in tests.
protocol UpdateQuestionPresenting {
    /// Calls `answer` with true for "Check Automatically".
    func askAboutAutomaticChecks(answer: @escaping (Bool) -> Void)
}

/// Opt-in updates (A4, architecture §7). No network until the user says yes:
/// - On first launch only, Lectern asks once whether to check automatically. Until the answer is
///   yes, Sparkle isn't even created, so it can't schedule a check or touch the network.
/// - The answer is kept in `ReaderPreferences` and can be changed in Settings; Lectern never asks
///   again.
/// - Check Now (Settings, or the app menu) is an explicit request and checks once whatever the
///   setting says.
/// There is no telemetry: Sparkle's system profile is never sent (`SUEnableSystemProfiling` is
/// off by default and Lectern never turns it on).
final class UpdateController {
    let preferences: ReaderPreferences
    private let makeUpdater: () -> any SoftwareUpdater
    private let question: any UpdateQuestionPresenting
    /// Created on first need: an opt-in at launch or in Settings, or Check Now.
    private(set) var updater: (any SoftwareUpdater)?
    private(set) var isAsking = false

    init(preferences: ReaderPreferences, question: any UpdateQuestionPresenting, makeUpdater: @escaping () -> any SoftwareUpdater) {
        self.preferences = preferences
        self.question = question
        self.makeUpdater = makeUpdater
    }

    /// At launch: ask the first-launch question, or start scheduled checks if the user opted in.
    func start() {
        switch preferences.checksForUpdatesAutomatically {
        case nil:
            guard !isAsking else { return }
            isAsking = true
            question.askAboutAutomaticChecks { [weak self] yes in
                guard let self else { return }
                isAsking = false
                setAutomaticChecks(yes)
            }
        case true?:
            updaterCreatingIfNeeded().automaticallyChecks = true
        case false?:
            break
        }
    }

    /// Whether the user has answered (at first launch or in Settings).
    var hasAnswered: Bool { preferences.checksForUpdatesAutomatically != nil }

    var automaticallyChecks: Bool { preferences.checksForUpdatesAutomatically ?? false }

    /// Settings' "Check for updates automatically", and the first-launch answer.
    func setAutomaticChecks(_ enabled: Bool) {
        preferences.checksForUpdatesAutomatically = enabled
        if enabled {
            updaterCreatingIfNeeded().automaticallyChecks = true
        } else {
            updater?.automaticallyChecks = false
        }
    }

    /// Check Now: one check, because the user asked.
    func checkNow() {
        updaterCreatingIfNeeded().checkNow()
    }

    private func updaterCreatingIfNeeded() -> any SoftwareUpdater {
        if let updater { return updater }
        let created = makeUpdater()
        // Before anything else runs: a check left scheduled by an earlier opt-in must not fire
        // after the user opted out.
        created.automaticallyChecks = automaticallyChecks
        updater = created
        return created
    }
}

// MARK: Sparkle

/// Sparkle 2 with its standard windows. The updater is configured before it starts, so a stale
/// `SUEnableAutomaticChecks` default from an earlier opt-in can't trigger a check.
final class SparkleUpdater: NSObject, SoftwareUpdater {
    private let controller: SPUStandardUpdaterController

    override init() {
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        super.init()
    }

    private var started = false

    private func startIfNeeded() {
        guard !started else { return }
        started = true
        controller.startUpdater()
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            controller.updater.automaticallyChecksForUpdates = newValue
            controller.updater.automaticallyDownloadsUpdates = false
            if newValue { startIfNeeded() }
        }
    }

    func checkNow() {
        startIfNeeded()
        controller.checkForUpdates(nil)
    }
}

/// The first-launch question, as an alert. "Don't Check" is the default button: nothing goes
/// over the network unless the user chooses it.
struct AlertUpdateQuestion: UpdateQuestionPresenting {
    func askAboutAutomaticChecks(answer: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Check for updates automatically?"
        alert.informativeText = "Lectern can check GitHub for a newer version once a day. Nothing about you or your documents is sent, and Lectern has no telemetry of any kind.\n\nYou can change this later in Settings."
        alert.addButton(withTitle: "Don’t Check")
        alert.addButton(withTitle: "Check Automatically")
        answer(alert.runModal() == .alertSecondButtonReturn)
    }
}

/// While hosting tests: records instead of reaching Sparkle or the network.
final class RecordingUpdater: SoftwareUpdater {
    var automaticallyChecks = false
    private(set) var checks = 0
    func checkNow() { checks += 1 }
}

/// While hosting tests: never asks; a test answers through `respond`.
final class RecordingUpdateQuestion: UpdateQuestionPresenting {
    private(set) var asked = 0
    private var pending: ((Bool) -> Void)?

    func askAboutAutomaticChecks(answer: @escaping (Bool) -> Void) {
        asked += 1
        pending = answer
    }

    func respond(_ yes: Bool) {
        let answer = pending
        pending = nil
        answer?(yes)
    }
}

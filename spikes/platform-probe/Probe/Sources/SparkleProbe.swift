#if PROBE_SPARKLE
import AppKit
import Sparkle

/// Experiment 4: an unattended Sparkle update. A headless user driver answers
/// "install" to every question and records each callback, so the script can
/// see how far the update got. After a successful install Sparkle relaunches
/// the app, which then records itself in `info` mode (buildTag shows v1 or v2).
final class SparkleProbe: NSObject {
    static let shared = SparkleProbe()
    private var recorder: Recorder!
    private var updater: SPUUpdater!

    func run(recorder: Recorder) {
        self.recorder = recorder
        let info = Bundle.main.infoDictionary ?? [:]
        recorder.step("sparkle-config", [
            "feed": info["SUFeedURL"] as? String ?? "",
            "publicKeyPresent": !((info["SUPublicEDKey"] as? String) ?? "").isEmpty,
            "installerLauncherService": info["SUEnableInstallerLauncherService"] as? Bool ?? false,
        ])
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        do {
            try updater.start()
            recorder.step("updater-start", ["ok": true])
        } catch {
            recorder.step("updater-start", ["ok": false, "error": error.probeDescription])
            done()
            return
        }
        updater.checkForUpdates()
        recorder.step("check-for-updates-called", [:])
    }

    private func note(_ name: String, _ fields: [String: Any] = [:]) { recorder.step("driver-\(name)", fields) }

    private func done() {
        recorder.finish()
        NSApp.terminate(nil)
    }
}

extension SparkleProbe: @preconcurrency SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        note("didAbortWithError", ["error": error.probeDescription,
                                   "reason": (error as NSError).localizedFailureReason ?? ""])
    }
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        note("willInstallUpdate", ["version": item.versionString])
    }
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        note("willRelaunchApplication")
        recorder.finish()
    }
}

extension SparkleProbe: @preconcurrency SPUUserDriver {
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        note("permissionRequest")
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { note("userInitiatedCheck") }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        note("updateFound", ["version": appcastItem.versionString,
                             "displayVersion": appcastItem.displayVersionString,
                             "stage": state.stage.rawValue])
        reply(.install)
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        note("updateNotFound", ["error": error.probeDescription])
        acknowledgement()
        done()
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        let ns = error as NSError
        var fields: [String: Any] = ["error": error.probeDescription,
                                     "reason": ns.localizedFailureReason ?? ""]
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            fields["underlying"] = ["domain": underlying.domain, "code": underlying.code,
                                    "description": underlying.localizedDescription]
        }
        note("updaterError", fields)
        acknowledgement()
        done()
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { note("downloadInitiated") }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        note("expectedContentLength", ["bytes": expectedContentLength])
    }
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() { note("extracting") }
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        note("readyToInstallAndRelaunch")
        reply(.install)
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        note("installing", ["applicationTerminated": applicationTerminated])
        recorder.finish()
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        note("installedAndRelaunched", ["relaunched": relaunched])
        acknowledgement()
    }
    func dismissUpdateInstallation() { note("dismissUpdateInstallation") }
}
#endif

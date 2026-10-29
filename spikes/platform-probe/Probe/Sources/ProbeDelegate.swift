import AppKit
import Darwin
import Security

/// Runs one experiment step per launch, records it, then quits.
///
/// Modes (`--mode`):
///   info               record identity only (also the default, e.g. after a Sparkle relaunch)
///   bookmark-create    wait for the file from `open -a probe file.pdf`, read it, store a
///                      security-scoped bookmark in the container
///   bookmark-resolve   control-read `--direct-path` values, then resolve the stored bookmark
///                      and read through it
///   container-write    write a marker file and a UserDefaults value
///   container-read     read them back
///   keychain-write     add generic-password items (legacy file keychain + data protection)
///   keychain-read      read them, non-interactively first, then interactively
///   keychain-delete    delete them
///   sparkle-update     (PlatformProbeSparkle only) check for and install an update
final class ProbeDelegate: NSObject, NSApplicationDelegate {
    private var openedURLs: [URL] = []
    private var recorder: Recorder!
    private var args: [String: [String]] = [:]

    static let keychainService = "io.github.ronimoe.PlatformProbe.m0c-test"

    func application(_ application: NSApplication, open urls: [URL]) {
        openedURLs.append(contentsOf: urls)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        args = Self.parse(ProcessInfo.processInfo.arguments)
        let mode = args["--mode"]?.last ?? "info"
        let runID = args["--run-id"]?.last ?? "launch-\(Int(Date().timeIntervalSince1970))-\(getpid())"
        recorder = Recorder(runID: runID, mode: mode)
        recorder.step("launched", ["arguments": ProcessInfo.processInfo.arguments])

        Task { @MainActor in
            await self.run(mode: mode)
            if mode != "sparkle-update" {
                self.recorder.finish()
                NSApp.terminate(nil)
            }
        }
    }

    private func run(mode: String) async {
        switch mode {
        case "info": break
        case "bookmark-create": await bookmarkCreate()
        case "bookmark-resolve": bookmarkResolve()
        case "container-write": containerWrite()
        case "container-read": containerRead()
        case "keychain-write": keychainWrite()
        case "keychain-read": keychainRead()
        case "keychain-delete": keychainDelete()
        case "sparkle-update":
            #if PROBE_SPARKLE
            SparkleProbe.shared.run(recorder: recorder)
            #else
            recorder.step("error", ["message": "this build has no Sparkle"])
            recorder.finish()
            NSApp.terminate(nil)
            #endif
        default: recorder.step("error", ["message": "unknown mode \(mode)"])
        }
    }

    // MARK: Experiment 1: security-scoped bookmarks

    private var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("PlatformProbe", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private var bookmarkFile: URL { supportDir.appendingPathComponent("test.bookmark") }

    private func bookmarkCreate() async {
        for _ in 0..<100 where openedURLs.isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let url = openedURLs.first else {
            recorder.step("open-event", ["ok": false, "message": "no file arrived via the open event"])
            return
        }
        recorder.step("open-event", ["ok": true, "path": url.path])
        recorder.step("read-via-open-event", readFile(url))
        do {
            let data = try url.bookmarkData(options: [.withSecurityScope],
                                            includingResourceValuesForKeys: nil, relativeTo: nil)
            try data.write(to: bookmarkFile, options: .atomic)
            recorder.step("create-bookmark", ["ok": true, "bytes": data.count, "storedAt": bookmarkFile.path])
        } catch {
            recorder.step("create-bookmark", ["ok": false, "error": error.probeDescription])
        }
    }

    private func bookmarkResolve() {
        // Control: the sandbox must deny a plain read of the path, or the bookmark proves nothing.
        for path in args["--direct-path"] ?? [] {
            recorder.step("control-direct-read", ["path": path].merging(posixRead(path)) { $1 })
        }
        guard let data = try? Data(contentsOf: bookmarkFile) else {
            recorder.step("load-bookmark", ["ok": false, "path": bookmarkFile.path])
            return
        }
        recorder.step("load-bookmark", ["ok": true, "bytes": data.count])
        var stale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
            recorder.step("resolve-bookmark", ["ok": true, "path": url.path, "isStale": stale])
        } catch {
            recorder.step("resolve-bookmark", ["ok": false, "error": error.probeDescription])
            return
        }
        let accessing = url.startAccessingSecurityScopedResource()
        recorder.step("start-accessing", ["ok": accessing])
        recorder.step("read-via-bookmark", readFile(url))
        if stale {
            // What Lectern would do: refresh the stored bookmark while access is held.
            do {
                let fresh = try url.bookmarkData(options: [.withSecurityScope],
                                                 includingResourceValuesForKeys: nil, relativeTo: nil)
                try fresh.write(to: bookmarkFile, options: .atomic)
                recorder.step("refresh-stale-bookmark", ["ok": true, "bytes": fresh.count])
            } catch {
                recorder.step("refresh-stale-bookmark", ["ok": false, "error": error.probeDescription])
            }
        }
        if accessing { url.stopAccessingSecurityScopedResource() }
    }

    private func readFile(_ url: URL) -> [String: Any] {
        do {
            let data = try Data(contentsOf: url)
            let bytes = [UInt8](data)
            return ["ok": true, "bytes": data.count,
                    "startsWithPDF": data.starts(with: Array("%PDF-".utf8)),
                    "checksum": ProbeBuild.checksum(bytes)]
        } catch {
            var result: [String: Any] = ["ok": false, "error": error.probeDescription]
            if let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError {
                result["underlying"] = ["domain": underlying.domain, "code": underlying.code]
            }
            return result
        }
    }

    private func posixRead(_ path: String) -> [String: Any] {
        let fd = open(path, O_RDONLY)
        if fd < 0 {
            let err = errno
            return ["ok": false, "errno": Int(err), "strerror": String(cString: strerror(err))]
        }
        close(fd)
        return ["ok": true]
    }

    // MARK: Experiment 2: the container

    private var markerFile: URL { supportDir.appendingPathComponent("container-marker.json") }

    private func containerWrite() {
        let tag = Bundle.main.infoDictionary?["ProbeBuildTag"] as? String ?? "?"
        let marker: [String: Any] = ["writtenBy": tag, "at": ISO8601DateFormatter().string(from: Date())]
        do {
            let data = try JSONSerialization.data(withJSONObject: marker)
            try data.write(to: markerFile, options: .atomic)
            recorder.step("write-marker", ["ok": true, "path": markerFile.path])
        } catch {
            recorder.step("write-marker", ["ok": false, "error": error.probeDescription])
        }
        UserDefaults.standard.set(tag, forKey: "m0cWrittenBy")
        recorder.step("write-defaults", ["ok": UserDefaults.standard.synchronize()])
    }

    private func containerRead() {
        do {
            let data = try Data(contentsOf: markerFile)
            let json = try JSONSerialization.jsonObject(with: data)
            recorder.step("read-marker", ["ok": true, "content": json])
        } catch {
            recorder.step("read-marker", ["ok": false, "error": error.probeDescription])
        }
        recorder.step("read-defaults", ["value": UserDefaults.standard.string(forKey: "m0cWrittenBy") ?? NSNull()])
        // Can this build still write to the container?
        let probe = supportDir.appendingPathComponent("written-by-\(getpid()).txt")
        do {
            try Data("x".utf8).write(to: probe)
            try FileManager.default.removeItem(at: probe)
            recorder.step("write-new-file", ["ok": true])
        } catch {
            recorder.step("write-new-file", ["ok": false, "error": error.probeDescription])
        }
    }

    // MARK: Experiment 3: the Keychain

    private enum KeychainVariant: String, CaseIterable {
        case legacy   // file-based login keychain (what an app without keychain-access-groups gets)
        case dataProtection
    }

    private func query(_ variant: KeychainVariant) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: variant.rawValue,
        ]
        if variant == .dataProtection { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    private func keychainWrite() {
        for variant in KeychainVariant.allCases {
            let base = query(variant)
            let deleted = SecItemDelete(base as CFDictionary)
            var add = base
            add[kSecValueData as String] = Data("secret-\(variant.rawValue)".utf8)
            add[kSecAttrLabel as String] = "Lectern M0c probe test item (\(variant.rawValue))"
            let status = SecItemAdd(add as CFDictionary, nil)
            recorder.step("add-\(variant.rawValue)", ["status": Int(status), "message": Self.message(status),
                                                       "priorDeleteStatus": Int(deleted)])
        }
    }

    private func keychainRead() {
        let only = args["--variant"]?.last
        for variant in KeychainVariant.allCases where only == nil || only == variant.rawValue {
            // Attributes only: never needs the item's ACL, so never prompts.
            var attrs = query(variant)
            attrs[kSecReturnAttributes as String] = true
            var out: CFTypeRef?
            var status = SecItemCopyMatching(attrs as CFDictionary, &out)
            recorder.step("\(variant.rawValue)-attributes", ["status": Int(status), "message": Self.message(status)])

            // Secret, with UI forbidden: a prompt would turn into errSecInteractionNotAllowed.
            var secret = query(variant)
            secret[kSecReturnData as String] = true
            var silent = secret
            silent[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
            SecKeychainSetUserInteractionAllowed(false)
            out = nil
            status = SecItemCopyMatching(silent as CFDictionary, &out)
            SecKeychainSetUserInteractionAllowed(true)
            recorder.step("\(variant.rawValue)-data-noninteractive",
                          ["status": Int(status), "message": Self.message(status),
                           "valueMatches": Self.matches(out, variant)])

            if args["--interactive"]?.last == "yes" {
                // May block on a SecurityAgent prompt; the script times out and kills us.
                recorder.step("\(variant.rawValue)-data-interactive-begin", [:])
                out = nil
                status = SecItemCopyMatching(secret as CFDictionary, &out)
                recorder.step("\(variant.rawValue)-data-interactive",
                              ["status": Int(status), "message": Self.message(status),
                               "valueMatches": Self.matches(out, variant)])
            }
        }
    }

    private func keychainDelete() {
        for variant in KeychainVariant.allCases {
            let status = SecItemDelete(query(variant) as CFDictionary)
            recorder.step("delete-\(variant.rawValue)", ["status": Int(status), "message": Self.message(status)])
        }
    }

    private static func matches(_ value: CFTypeRef?, _ variant: KeychainVariant) -> Bool {
        guard let data = value as? Data else { return false }
        return String(decoding: data, as: UTF8.self) == "secret-\(variant.rawValue)"
    }

    private static func message(_ status: OSStatus) -> String {
        SecCopyErrorMessageString(status, nil) as String? ?? "\(status)"
    }

    // MARK: Arguments

    private static func parse(_ argv: [String]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        var i = 1
        while i < argv.count {
            let key = argv[i]
            if key.hasPrefix("--"), i + 1 < argv.count {
                result[key, default: []].append(argv[i + 1])
                i += 2
            } else {
                i += 1
            }
        }
        return result
    }
}

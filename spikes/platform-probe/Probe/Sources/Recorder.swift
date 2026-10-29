import Foundation

/// Writes the run's result JSON into the container after every step, so a later
/// hang (for example a Keychain prompt nobody answers) never loses earlier steps.
final class Recorder {
    let url: URL
    private var root: [String: Any]
    private var steps: [[String: Any]] = []

    init(runID: String, mode: String) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("PlatformProbe/results", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("\(runID).json")
        let info = Bundle.main.infoDictionary ?? [:]
        root = [
            "runID": runID,
            "mode": mode,
            "buildTag": info["ProbeBuildTag"] as? String ?? "?",
            "codeVariant": ProbeBuild.codeVariant,
            "bundleVersion": info["CFBundleVersion"] as? String ?? "?",
            "bundlePath": Bundle.main.bundlePath,
            "home": NSHomeDirectory(),
            "sandboxed": ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "started": ISO8601DateFormatter().string(from: Date()),
            "complete": false,
        ]
        flush()
    }

    func step(_ name: String, _ fields: [String: Any]) {
        var entry = fields
        entry["step"] = name
        entry["at"] = ISO8601DateFormatter().string(from: Date())
        steps.append(entry)
        flush()
    }

    func finish() {
        root["complete"] = true
        root["finished"] = ISO8601DateFormatter().string(from: Date())
        flush()
    }

    private func flush() {
        var doc = root
        doc["steps"] = steps
        guard let data = try? JSONSerialization.data(
            withJSONObject: doc, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

extension Error {
    var probeDescription: [String: Any] {
        let ns = self as NSError
        return ["domain": ns.domain, "code": ns.code, "description": ns.localizedDescription]
    }
}

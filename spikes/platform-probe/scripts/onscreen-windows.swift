// Lists on-screen windows owned by processes that show system dialogs
// (SecurityAgent, UserNotificationCenter, CoreServicesUIAgent, ...) or by the probe.
// Owner names and bounds don't need Screen Recording permission; titles would.
import CoreGraphics
import Foundation

let watched = ["SecurityAgent", "UserNotificationCenter", "CoreServicesUIAgent",
               "universalAccessAuthWarn", "PlatformProbe", "PlatformProbeSparkle", "Sparkle", "Updater"]
let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]] ?? []
var found = 0
for w in info {
    let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
    guard watched.contains(where: { owner.contains($0) }) else { continue }
    let pid = w[kCGWindowOwnerPID as String] as? Int ?? 0
    let layer = w[kCGWindowLayer as String] as? Int ?? 0
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    print("window owner=\(owner) pid=\(pid) layer=\(layer) size=\(b["Width"] ?? "?")x\(b["Height"] ?? "?")")
    found += 1
}
if found == 0 { print("no dialog windows on screen (\(info.count) on-screen windows checked)") }

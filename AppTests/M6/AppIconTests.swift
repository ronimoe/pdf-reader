import AppKit
import Testing

/// The app icon (design/logo/README.md) is compiled from App/AppIcon.icon into the bundle: the
/// full set of sizes and appearances lives in Assets.car, with a small AppIcon.icns as the fallback.
@Suite(.noUI)
struct AppIconTests {
    @Test func theBundleNamesAndCarriesTheIcon() throws {
        let info = try #require(Bundle.main.infoDictionary)
        #expect(info["CFBundleIconName"] as? String == "AppIcon")
        #expect(info["CFBundleIconFile"] as? String == "AppIcon")
        let icns = try #require(Bundle.main.url(forResource: "AppIcon", withExtension: "icns"))
        let image = try #require(NSImage(contentsOf: icns))
        #expect(!image.representations.isEmpty)
        #expect(Bundle.main.url(forResource: "Assets", withExtension: "car") != nil)
    }
}

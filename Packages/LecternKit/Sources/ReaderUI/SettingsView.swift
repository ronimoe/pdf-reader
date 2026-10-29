import AppKit
import ReaderCore
import SwiftUI

/// What the Settings window shows and changes. The app connects each setting to its stored
/// preference through the `on…` callbacks.
@Observable
public final class SettingsModel {
    // General
    public var sessionRestore: SessionRestorePolicy { didSet { if sessionRestore != oldValue { onChange(.sessionRestore) } } }
    public var previewsLinksOnHover: Bool { didSet { if previewsLinksOnHover != oldValue { onChange(.previewsLinksOnHover) } } }
    public var distractionFreeEntersFullScreen: Bool { didSet { if distractionFreeEntersFullScreen != oldValue { onChange(.distractionFreeEntersFullScreen) } } }
    /// Read-only: what macOS's "Close windows when quitting an application" says.
    public var systemKeepsWindows: Bool

    // Annotations
    /// Empty by default; never filled in from the Mac account (B4).
    public var annotationAuthor: String { didSet { if annotationAuthor != oldValue { onChange(.annotationAuthor) } } }
    public var annotationColor: AnnotationColorPreset { didSet { if annotationColor != oldValue { onChange(.annotationColor) } } }

    // Updates (A4)
    public var checksForUpdatesAutomatically: Bool { didSet { if checksForUpdatesAutomatically != oldValue { onChange(.checksForUpdatesAutomatically) } } }

    public enum Setting: Hashable {
        case sessionRestore, previewsLinksOnHover, distractionFreeEntersFullScreen
        case annotationAuthor, annotationColor, checksForUpdatesAutomatically
    }

    @ObservationIgnored public var onChange: (Setting) -> Void = { _ in }
    @ObservationIgnored public var onCheckNow: () -> Void = {}

    public init(
        sessionRestore: SessionRestorePolicy = .default,
        previewsLinksOnHover: Bool = true,
        distractionFreeEntersFullScreen: Bool = false,
        systemKeepsWindows: Bool = false,
        annotationAuthor: String = "",
        annotationColor: AnnotationColorPreset = .default,
        checksForUpdatesAutomatically: Bool = false
    ) {
        self.sessionRestore = sessionRestore
        self.previewsLinksOnHover = previewsLinksOnHover
        self.distractionFreeEntersFullScreen = distractionFreeEntersFullScreen
        self.systemKeepsWindows = systemKeepsWindows
        self.annotationAuthor = annotationAuthor
        self.annotationColor = annotationColor
        self.checksForUpdatesAutomatically = checksForUpdatesAutomatically
    }
}

/// Settings (⌘,): General, Annotations and Updates, as a native tabbed settings window.
public struct SettingsView: View {
    @Bindable private var model: SettingsModel
    @State private var tab: Tab

    public enum Tab: String, Hashable, CaseIterable {
        case general, annotations, updates
    }

    public init(model: SettingsModel, tab: Tab = .general) {
        self.model = model
        _tab = State(initialValue: tab)
    }

    public var body: some View {
        TabView(selection: $tab) {
            general
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
            annotations
                .tabItem { Label("Annotations", systemImage: "highlighter") }
                .tag(Tab.annotations)
            updates
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
                .tag(Tab.updates)
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var general: some View {
        Form {
            Picker("Reopen documents on launch:", selection: $model.sessionRestore) {
                ForEach(SessionRestorePolicy.allCases, id: \.self) { policy in
                    Text(policy.title).tag(policy)
                }
            }
            .accessibilityLabel("Reopen documents on launch")
            Text(model.systemKeepsWindows
                ? "macOS is set to keep windows when quitting, so Lectern reopens them."
                : "macOS is set to close windows when quitting (Desktop & Dock), so Lectern doesn’t reopen them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 300, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(model.sessionRestore == .system ? 1 : 0)
                .accessibilityHidden(model.sessionRestore != .system)
            Toggle("Preview links on hover", isOn: $model.previewsLinksOnHover)
                .help("Also in View ▸ Preview Links on Hover. Keyboard: ⌥⇥ then Space.")
            Toggle("Enter full screen in distraction-free mode", isOn: $model.distractionFreeEntersFullScreen)
        }
        .padding(20)
    }

    private var annotations: some View {
        Form {
            TextField("Author name:", text: $model.annotationAuthor, prompt: Text("None"))
                .accessibilityLabel("Author name")
            Text("Written into new annotations only. Leave it empty to add no name.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 300, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Highlight colour:", selection: $model.annotationColor) {
                ForEach(AnnotationColorPreset.allCases, id: \.self) { preset in
                    Label {
                        Text(preset.name)
                    } icon: {
                        Image(nsImage: Self.swatch(preset))
                    }
                    .tag(preset)
                }
            }
            .accessibilityLabel("Highlight colour")
        }
        .padding(20)
    }

    private var updates: some View {
        Form {
            Toggle("Check for updates automatically", isOn: $model.checksForUpdatesAutomatically)
            Text("At most once a day, from GitHub. Nothing about you or your documents is sent.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 300, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button("Check Now") { model.onCheckNow() }
                .accessibilityLabel("Check for updates now")
            Divider()
            Label("Lectern sends no telemetry: no analytics, crash reports or usage data.", systemImage: "hand.raised")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 300, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }

    /// A round swatch, always beside the colour's name (Rule 8).
    static func swatch(_ preset: AnnotationColorPreset) -> NSImage {
        let rgb = preset.rgb
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            NSColor.black.withAlphaComponent(0.25).setStroke()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
            return true
        }
        image.accessibilityDescription = preset.name
        return image
    }
}

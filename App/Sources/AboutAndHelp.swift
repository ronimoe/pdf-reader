import AppKit

/// Text files shipped inside the app: the GPL-3.0 (`LICENSE`), the third-party notices
/// (`Acknowledgements.txt`) and the known limitations (`known-limitations.md`, the same file as
/// docs/known-limitations.md).
enum AppResources {
    static let sourceRepository = URL(string: "https://github.com/ronimoe/pdf-reader")!

    static func text(_ name: String, in bundle: Bundle = .main) -> String? {
        let url = URL(fileURLWithPath: name)
        let ext = url.pathExtension
        guard let file = bundle.url(forResource: url.deletingPathExtension().lastPathComponent, withExtension: ext.isEmpty ? nil : ext) else {
            return nil
        }
        return try? String(contentsOf: file, encoding: .utf8)
    }
}

/// Lectern ▸ About Lectern: name, version, copyright, the source repository, the licence and the
/// no-telemetry promise (spec §11, Goal 5).
enum AboutPanel {
    static func options(bundle: Bundle = .main) -> [NSApplication.AboutPanelOptionKey: Any] {
        let info = bundle.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        let build = info["CFBundleVersion"] as? String ?? ""
        return [
            .applicationName: "Lectern",
            .applicationVersion: version,
            .version: "Build \(build)",
            .credits: credits(),
        ]
    }

    static func credits() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 6
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        let text = NSMutableAttributedString(string: "A free, open-source PDF reader for the Mac.\n", attributes: base)
        text.append(NSAttributedString(string: "No telemetry, no accounts, no ads and no AI. Lectern works offline and goes online only to check for updates, and only if you turn that on.\n", attributes: base))
        var link = base
        link[.link] = AppResources.sourceRepository
        text.append(NSAttributedString(string: "Source code: ", attributes: base))
        text.append(NSAttributedString(string: AppResources.sourceRepository.absoluteString.replacingOccurrences(of: "https://", with: ""), attributes: link))
        text.append(NSAttributedString(string: "\nFree software under the GNU General Public License, version 3 (Help ▸ Licence). Third-party notices: Help ▸ Acknowledgements.", attributes: base))
        return text
    }
}

/// A read-only window showing one of `AppResources`' text files: Help ▸ Licence,
/// Acknowledgements and Known Limitations.
final class TextDocumentWindowController: NSWindowController {
    let resource: String
    let textView: NSTextView

    init(title: String, resource: String, bundle: Bundle = .main) {
        self.resource = resource
        let scroll = NSTextView.scrollableTextView()
        textView = scroll.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.string = AppResources.text(resource, in: bundle) ?? "\(resource) is missing from this copy of Lectern."
        textView.setAccessibilityLabel(title)
        let controller = NSViewController()
        controller.view = scroll
        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.isRestorable = false
        window.setContentSize(NSSize(width: 640, height: 600))
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        guard let window else { return }
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    override func cancelOperation(_ sender: Any?) {
        window?.performClose(sender)
    }
}

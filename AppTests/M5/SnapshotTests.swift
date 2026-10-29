import AppKit
import PDFKit
import Persistence
import ReaderCore
import ReaderKit
import ReaderUI
import SwiftUI
import Testing
@testable import Lectern

/// Renders windows offscreen, never ordered on screen, in light and dark, so the look can be
/// inspected without screen access. The sandboxed test host writes to its own temporary folder
/// (`LecternSnapshots`); `scripts/test.sh` copies the PNGs to `build/snapshots/`. PDFKit's
/// annotations don't appear in offscreen captures (M0b Q11).
@MainActor
enum Snapshot {
    static var folder: URL {
        FileManager.default.temporaryDirectory.appending(path: "LecternSnapshots", directoryHint: .isDirectory)
    }

    static let appearances: [(name: String, appearance: NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]

    /// The whole window, title bar and toolbar included, as an image, from a window that is never
    /// ordered in.
    ///
    /// Offscreen, `cacheDisplay` replays only what views draw themselves: PDFKit's pages come out
    /// empty (M0b Q11), and macOS 26's glass and backdrop views draw a white fallback that hides
    /// everything in dark mode. So the image is composed: the window background, a panel for each
    /// glass container, every visible PDF page drawn with `PDFPage.draw(with:to:)` (annotations
    /// included), then the views' own drawing with the glass and backdrop views hidden.
    static func image(of window: NSWindow) throws -> NSBitmapImageRep {
        let root = try #require(window.contentView?.superview ?? window.contentView)
        #expect(!window.isVisible, "snapshots never order a window in")
        root.layoutSubtreeIfNeeded()
        let size = root.bounds.size
        let scale: CGFloat = 2
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        let all = views(in: root)
        let decorative = all.filter { isDecorative($0) && !$0.isHidden }
        let glass = all.filter { String(describing: type(of: $0)).contains("GlassEffect") && !$0.isHiddenOrHasHiddenAncestor }
        let pdfViews = all.compactMap { $0 as? PDFView }.filter { !$0.isHiddenOrHasHiddenAncestor }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.current = context
        root.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: size).fill()
            for view in glass {
                NSColor.controlBackgroundColor.setFill()
                NSBezierPath(roundedRect: view.convert(view.bounds, to: nil), xRadius: 14, yRadius: 14).fill()
            }
            for view in pdfViews { drawPages(of: view, in: context.cgContext) }
        }
        // PDFKit's page views paint blank white offscreen; the pages are already drawn above.
        let pageScrollers = pdfViews.compactMap { $0.documentView?.enclosingScrollView }.filter { !$0.isHidden }
        let hidden = decorative + pageScrollers
        hidden.forEach { $0.isHidden = true }
        defer { hidden.forEach { $0.isHidden = false } }
        // The window and the PDF views paint their backgrounds in this pass too, over the pages.
        let background = (window.backgroundColor, window.isOpaque, pdfViews.map(\.backgroundColor))
        window.isOpaque = false
        window.backgroundColor = .clear
        pdfViews.forEach { $0.backgroundColor = .clear }
        defer {
            window.backgroundColor = background.0
            window.isOpaque = background.1
            zip(pdfViews, background.2).forEach { $0.backgroundColor = $1 }
        }
        let chrome = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: chrome)
        chrome.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        return rep
    }

    /// macOS 26's glass and backdrop views, which offscreen draw only a white fallback. The glass
    /// containers themselves stay: they hold the sidebar.
    static func isDecorative(_ view: NSView) -> Bool {
        // Controls draw through `_NSCoreHostingView<AppKit…>` and stay; the glass behind them is
        // `_NSCoreHostingView<RootView>`.
        let name = String(describing: type(of: view))
        return name.hasPrefix("_NSCoreHostingView<RootView>")
            || ["Backdrop", "TitlebarBackground", "Pocket", "BlurryAlleyway"].contains { name.contains($0) }
    }

    static func views(in root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(views(in:))
    }

    /// A PDF view's background and its visible pages, at their places in the window.
    static func drawPages(of view: PDFView, in cg: CGContext) {
        // Below the toolbar: in the app, the title bar's material covers what scrolls under it.
        let visible = view.convert(view.safeAreaRect, to: nil)
        cg.saveGState()
        cg.clip(to: visible)
        view.backgroundColor.setFill()
        visible.fill()
        if let document = view.document {
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                let box = page.bounds(for: view.displayBox)
                let inView = view.convert(box, from: page)
                guard inView.intersects(view.bounds) else { continue }
                let rect = view.convert(inView, to: nil)
                NSColor.white.setFill()
                rect.fill()
                cg.saveGState()
                cg.translateBy(x: rect.minX, y: rect.minY)
                cg.scaleBy(x: rect.width / box.width, y: rect.height / box.height)
                cg.translateBy(x: -box.minX, y: -box.minY)
                page.draw(with: view.displayBox, to: cg)
                cg.restoreGState()
            }
        }
        cg.restoreGState()
    }

    /// The image of a view hosted in its own transparent, offscreen window.
    static func image(of view: NSView, size: NSSize, appearance: NSAppearance.Name) throws -> NSBitmapImageRep {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        defer { window.contentView = nil }
        let rep = try image(of: window)
        return rep
    }

    /// In points: how far the first content (anything unlike the background) is from the left
    /// and right edges, looking only below the top `belowTop` points (the title and tab bars).
    static func inkMargins(_ rep: NSBitmapImageRep, belowTop: CGFloat) -> (left: CGFloat, right: CGFloat) {
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        let top = Int(belowTop * scale)
        let rows = stride(from: top, to: rep.pixelsHigh - Int(4 * scale), by: 2)
        func luminance(_ x: Int, _ y: Int) -> CGFloat {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return 0 }
            return (c.redComponent + c.greenComponent + c.blueComponent) / 3
        }
        let background = luminance(rep.pixelsWide / 2, rep.pixelsHigh - Int(6 * scale))
        func hasInk(_ x: Int) -> Bool { rows.contains { abs(luminance(x, $0) - background) > 0.25 } }
        let edge = Int(2 * scale)
        let left = (edge..<rep.pixelsWide).first(where: hasInk) ?? rep.pixelsWide
        let right = (0..<(rep.pixelsWide - edge)).reversed().first(where: hasInk) ?? 0
        return (CGFloat(left) / scale, CGFloat(rep.pixelsWide - 1 - right) / scale)
    }

    /// The fractions of near-white and near-black pixels, sampled.
    static func tones(_ rep: NSBitmapImageRep) -> (white: Double, dark: Double) {
        var white = 0, dark = 0, total = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                total += 1
                let l = (c.redComponent + c.greenComponent + c.blueComponent) / 3
                if l > 0.95 { white += 1 } else if l < 0.2 { dark += 1 }
            }
        }
        return (Double(white) / Double(max(total, 1)), Double(dark) / Double(max(total, 1)))
    }

    @discardableResult
    static func write(_ rep: NSBitmapImageRep, _ name: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "\(name).png")
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    /// `base` with `overlay` drawn at `origin` (bottom-left based), with a soft shadow, as a
    /// popover sits over the window.
    static func composite(_ base: NSBitmapImageRep, _ overlay: NSBitmapImageRep, at origin: NSPoint) throws -> NSBitmapImageRep {
        let size = NSSize(width: base.pixelsWide, height: base.pixelsHigh)
        let result = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: base.pixelsWide, pixelsHigh: base.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        result.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: result)
        base.draw(in: NSRect(origin: .zero, size: size))
        let scale = CGFloat(base.pixelsWide) / base.size.width
        let rect = NSRect(x: origin.x * scale, y: origin.y * scale, width: CGFloat(overlay.pixelsWide), height: CGFloat(overlay.pixelsHigh))
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 16 * scale
        shadow.shadowOffset = NSSize(width: 0, height: -4 * scale)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        let path = NSBezierPath(roundedRect: rect, xRadius: 10 * scale, yRadius: 10 * scale)
        NSColor.windowBackgroundColor.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        path.addClip()
        overlay.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        return result
    }
}

extension M5Tests {
    @MainActor
    @Suite struct SnapshotTests {
        /// A reader window that is never ordered on screen.
        /// Opened from a file, as the app opens documents, so the title is the file's name.
        private static let folder = try! TemporaryFolder()

        private func reader(_ data: Data, size: NSSize = NSSize(width: 1100, height: 760)) throws -> (ReaderDocument, ReaderWindowController) {
            let file = try Self.folder.write(data, to: "MuseGNN \(UUID().uuidString.prefix(4)).pdf")
            let document = try ReaderDocument.opened(file)
            let controller = ReaderWindowController(
                document: document, passwordStore: InMemoryPasswordStore(), presenter: RecordingPresenter(), stateStore: nil,
                previewPresenter: nil, urlOpener: RecordingURLOpener(), preferences: .ephemeral(), journal: nil
            )
            document.addWindowController(controller)
            let window = try #require(controller.window)
            window.setFrameAutosaveName("")
            window.toolbar?.autosavesConfiguration = false
            window.setContentSize(size)
            controller.splitViewController.view.layoutSubtreeIfNeeded()
            #expect(!window.isVisible)
            #expect(window.title == document.displayName && window.title.hasPrefix("MuseGNN"), "the title is the file's name: \(window.title)")
            return (document, controller)
        }

        private func paper() throws -> Data { try LinkFixture.arxivPaper() }

        /// Captures both appearances. Every capture must have content; with `pages`, enough dark
        /// pixels to be page text, and without, a dark capture mustn't be mostly white (the glass
        /// fallback that hid everything before the capture was composed).
        private func shoot(_ window: NSWindow, _ name: String, pages: Bool = false, prepare: () -> Void = {}) throws {
            for (suffix, appearance) in Snapshot.appearances {
                window.appearance = NSAppearance(named: appearance)
                prepare()
                spin(timeout: 0.3) { false }
                let rep = try Snapshot.image(of: window)
                try Snapshot.write(rep, "\(name)-\(suffix)")
                let (white, dark) = Snapshot.tones(rep)
                if pages { #expect(dark > 0.005, "\(name)-\(suffix): no page text (\(dark))") }
                if !pages, suffix == "dark" { #expect(white < 0.25, "\(name)-\(suffix): mostly white (\(white))") }
                if !pages, suffix == "light" { #expect(dark < 0.5, "\(name)-\(suffix): mostly dark (\(dark))") }
            }
            #expect(!window.isVisible, "never ordered on screen")
        }

        @Test func emptyState() throws {
            let urls = ["Field Notes.pdf", "A Paper About Things.pdf", "Quarterly Report.pdf"].map { URL(fileURLWithPath: "/Users/reader/Documents/\($0)") }
            let controller = EmptyStateController(recentURLs: { urls }, openDocument: {}, openURLs: { _ in })
            let window = controller.prepareWindow()
            try shoot(window, "empty-state")
        }

        @Test func documentWithSidebar() throws {
            let (document, controller) = try reader(try paper())
            defer { document.close() }
            controller.setSidebarVisible(true)
            controller.showSidebarSection(.outline)
            let window = try #require(controller.window)
            try shoot(window, "document-sidebar", pages: true)
            controller.showSidebarSection(.thumbnails)
            spin(timeout: 1.5) { false }
            try shoot(window, "document-thumbnails", pages: true)
        }

        @Test func split() throws {
            let (document, controller) = try reader(try paper(), size: NSSize(width: 1300, height: 760))
            defer { document.close() }
            controller.openSplit(at: controller.primaryPane.view.topAnchor(forPageAt: 3))
            try shoot(try #require(controller.window), "split", pages: true)
        }

        @Test func annotationPopover() throws {
            let (document, controller) = try reader(try paper())
            defer { document.close() }
            let window = try #require(controller.window)
            let view = controller.pdfView
            let page = try #require(view.document?.page(at: 0))
            let selection = try #require(page.selection(for: CGRect(x: 100, y: 500, width: 300, height: 40)))
            view.setCurrentSelection(selection, animate: false)
            for (suffix, appearance) in Snapshot.appearances {
                window.appearance = NSAppearance(named: appearance)
                view.selectionBar.isHidden = false
                view.selectionBar.setFrameOrigin(NSPoint(x: 160, y: view.bounds.height - 240))
                spin(timeout: 0.3) { false }
                let base = try Snapshot.image(of: window)
                #expect(Snapshot.tones(base).dark > 0.005, "annotation-popover-\(suffix): no page text")
                let editor = AnnotationTextEditorController(heading: "Comment", text: "Check this against the second experiment before citing it. The convergence bound in section 4 assumes a fixed sampling rate, which the ablation in the appendix doesn't use.")
                _ = editor.view
                let size = editor.preferredContentSize
                let overlay = try Snapshot.image(of: editor.view, size: size, appearance: appearance)
                try Snapshot.write(try Snapshot.composite(base, overlay, at: NSPoint(x: 240, y: window.frame.height - 470)), "annotation-popover-\(suffix)")
            }
        }

        @Test func settings() throws {
            let preferences = ReaderPreferences.ephemeral()
            let updates = UpdateController(preferences: preferences, question: RecordingUpdateQuestion()) { RecordingUpdater() }
            let model = SettingsWindowController(preferences: preferences, updates: updates, systemKeepsWindows: { false }).model
            for tab in SettingsView.Tab.allCases {
                // A window like SettingsWindowController's, opened on each tab.
                let hosting = NSHostingController(rootView: SettingsView(model: model, tab: tab))
                hosting.sizingOptions = [.preferredContentSize]
                let window = NSWindow(contentViewController: hosting)
                window.styleMask = [.titled, .closable]
                window.title = "Settings"
                window.isReleasedWhenClosed = false
                try shoot(window, "settings-\(tab.rawValue)")
                // Standard form insets: nothing within 16 pt of either side.
                for (suffix, appearance) in Snapshot.appearances {
                    window.appearance = NSAppearance(named: appearance)
                    let rep = try Snapshot.image(of: window)
                    let (left, right) = Snapshot.inkMargins(rep, belowTop: 60)
                    #expect(left >= 16 && right >= 16, "settings-\(tab.rawValue)-\(suffix): margins \(left), \(right)")
                }
            }
        }

        @Test func shortcutMap() throws {
            let controller = KeyboardShortcutsWindowController(menu: { MainMenu.make() })
            let window = try #require(controller.window)
            window.setContentSize(NSSize(width: 420, height: 620))
            try shoot(window, "shortcut-map")
        }

        @Test func distractionFree() throws {
            let (document, controller) = try reader(try paper())
            defer { document.close() }
            controller.setSidebarVisible(true)
            controller.setFullScreen = { _, _ in }
            controller.setDistractionFree(true)
            try shoot(try #require(controller.window), "distraction-free", pages: true)
        }
    }
}

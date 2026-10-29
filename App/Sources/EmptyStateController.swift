import AppKit
import ReaderKit
import ReaderUI
import SwiftUI

/// The window shown while no document is open (spec §4.3): Open Document and
/// the recent files. PDFs dropped on it are opened.
final class EmptyStateController {
    let model: EmptyStateModel
    private(set) var window: NSWindow?
    private let recentURLs: () -> [URL]

    init(
        recentURLs: @escaping () -> [URL] = { NSDocumentController.shared.recentDocumentURLs },
        openDocument: @escaping () -> Void = { NSDocumentController.shared.openDocument(nil) },
        openURLs: @escaping ([URL]) -> Void = { ReaderDocumentController.openDocuments(at: $0) }
    ) {
        self.recentURLs = recentURLs
        model = EmptyStateModel(onOpenDocument: openDocument, onOpenURLs: openURLs)
    }

    var isShown: Bool { window?.isVisible ?? false }

    func show() {
        prepareWindow().makeKeyAndOrderFront(nil)
    }

    /// The window with the current recents, without showing it (also for offscreen snapshots).
    @discardableResult
    func prepareWindow() -> NSWindow {
        model.setRecents(recentURLs())
        let window = window ?? makeWindow()
        self.window = window
        return window
    }

    func hide() {
        window?.orderOut(nil)
    }

    func documentsDidChange(count: Int) {
        if count == 0 { show() } else { hide() }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: true
        )
        window.title = ProcessInfo.processInfo.processName
        window.isReleasedWhenClosed = false
        // Never reopened by AppKit's window restoration (Lectern restores sessions itself).
        window.isRestorable = false
        // Document windows must never tab into this one.
        window.tabbingMode = .disallowed
        let content = DropTargetView(content: NSHostingView(rootView: EmptyStateView(model: model)))
        content.onTargetedChange = { [model] in model.isDropTargeted = $0 }
        content.onDrop = { [model] in model.onOpenURLs($0) }
        window.contentView = content
        window.center()
        return window
    }
}

/// Accepts PDF files dragged onto the empty-state window.
private final class DropTargetView: NSView {
    var onTargetedChange: (Bool) -> Void = { _ in }
    var onDrop: ([URL]) -> Void = { _ in }

    init(content: NSView) {
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let accepts = !ReaderPDFView.pdfURLs(on: sender.draggingPasteboard).isEmpty
        onTargetedChange(accepts)
        return accepts ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onTargetedChange(false)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        onTargetedChange(false)
        let urls = ReaderPDFView.pdfURLs(on: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        onDrop(urls)
        return true
    }
}

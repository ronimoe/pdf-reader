import AppKit
import ReaderKit

final class ReaderWindowController: NSWindowController {
    let pdfView = ReaderPDFView(frame: .zero)

    init(document: ReaderDocument) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 1000),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.tabbingMode = .preferred
        window.setFrameAutosaveName("ReaderWindow")
        super.init(window: window)
        window.contentView = pdfView
        pdfView.document = document.pdfDocument
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

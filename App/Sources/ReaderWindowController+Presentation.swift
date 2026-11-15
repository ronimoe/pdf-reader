import AppKit
import PDFKit
import ReaderCore
import ReaderKit
import ReaderUI

// MARK: Presentation mode (View ▸ Start Presentation, ⌥⌘P)

extension ReaderWindowController {
    var isPresenting: Bool { presentation != nil }

    @objc func togglePresentation(_ sender: Any?) {
        if isPresenting { endPresentation() } else { startPresentation() }
    }

    /// Shows the document one slide at a time over a whole display, from the page the focused
    /// pane is on. The slides are a view of their own on the same `PDFDocument`, like a link
    /// preview: this window, its panes, their settings, history and stored position don't
    /// change while they show (architecture §4.5).
    func startPresentation() {
        guard !isPresenting, isShowingContent, let readerDocument, let pdf = pdfView.document, pdf.pageCount > 0 else { return }
        dismissPreview()
        let source = focusedPane
        let controller = PresentationController(
            document: pdf,
            startingAt: source.view.pageIndexInMiddle ?? 0,
            numbering: readerDocument.pageNumbering,
            title: readerDocument.displayName
        )
        controller.onExternalLink = { [weak self, weak controller] target in
            guard let self, let controller else { return }
            followLinkFromSlide(target, in: controller)
        }
        controller.onDismissRequest = { [weak self, weak controller] in
            guard let self, let controller else { return }
            presentationPresenter.dismiss(controller)
        }
        controller.onEnd = { [weak self, weak source] lastIndex in
            self?.presentationDidEnd(at: lastIndex, source: source)
        }
        presentation = controller
        // Someone who has presented knows the command: slide decks needn't suggest it.
        preferences.hasSeenPresentationSuggestion = true
        presentationPresenter.present(controller, on: presentationScreen)
    }

    /// Ends the presentation. The reader then moves to the last slide shown, as a jump that Back
    /// undoes; `movingReader` is false when the window is closing or the document can't be shown.
    func endPresentation(movingReader: Bool = true) {
        guard let presentation else { return }
        if !movingReader {
            presentation.onEnd = nil
            self.presentation = nil
        }
        presentationPresenter.dismiss(presentation)
    }

    /// A sheet on this window (a question, an error, the unsaved-changes review at quit) would
    /// open behind the slides while Lectern is active, so the presentation ends first.
    @objc func windowWillBeginSheet(_ notification: Notification) {
        endPresentation()
    }

    private func presentationDidEnd(at lastIndex: Int, source: ReaderPane?) {
        presentation = nil
        // The pane the presentation started from, unless the split closed meanwhile.
        let pane = source.flatMap { source in panes.first { $0 === source } } ?? primaryPane
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(pane.view)
        }
        guard let document = pane.view.document, lastIndex < document.pageCount else { return }
        if pane.view.pageIndexInMiddle != lastIndex { pane.jump(toPageAt: lastIndex) }
    }

    /// Where the slides go. With more than one display, on one this window isn't on, as Keynote
    /// does, so the reader stays in view; otherwise on this window's display.
    var presentationScreen: NSScreen? {
        guard let own = window?.screen ?? NSScreen.main else { return NSScreen.screens.first }
        return NSScreen.screens.first { $0 != own } ?? own
    }

    /// A link on a slide that leaves the document. Web links open in the browser, as from the
    /// page (A4). A link that would ask first or be explained would put its sheet on this window,
    /// behind the slides, so the slide says why it wasn't followed instead.
    private func followLinkFromSlide(_ target: LinkTarget, in controller: PresentationController) {
        switch target {
        case .web:
            handleExternalLink(target)
        case .otherScheme:
            controller.notice.show("Links that open other apps aren’t followed during a presentation.", duration: 3)
        case let .blocked(type):
            controller.notice.show("\(BlockedLink(actionType: type).title).", duration: 3)
        case .destination, .named:
            break
        }
    }

    /// Opening a document that looks like slides suggests presenting it: once, ever, and never
    /// to someone who has presented already. The presentation itself only ever starts from the
    /// menu or ⌥⌘P.
    func suggestPresentationIfSlides() {
        guard let readerDocument, readerDocument.looksLikeSlides, !preferences.hasSeenPresentationSuggestion else { return }
        preferences.hasSeenPresentationSuggestion = true
        notice.show("This looks like a slide deck. To present it, choose View ▸ Start Presentation (⌥⌘P).", duration: 5)
    }
}

extension ReaderPDFView {
    /// The page in the middle of the part of the view not under the toolbar: the one being
    /// looked at, where a presentation starts and ends. Measured, because `currentPage` lags
    /// behind a jump made in code.
    var pageIndexInMiddle: Int? {
        guard let document else { return nil }
        let visible = unobscuredRectInView
        guard let page = page(for: CGPoint(x: visible.midX, y: visible.midY), nearest: true) else { return nil }
        let index = document.index(for: page)
        return index == NSNotFound ? nil : index
    }
}

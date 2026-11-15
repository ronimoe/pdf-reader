import AppKit
import PDFKit
import ReaderCore
import ReaderKit
import Testing
@testable import Lectern

extension M3Tests {
    /// Citation previews: a citation previews the cited work, read offline from the paper's
    /// reference list, instead of the reference list's page. Every other link still previews its
    /// page. On the bundled arXiv paper (CC BY 4.0), whose reference list starts on page 11.
    @MainActor
    @Suite struct CitationPreview {
        /// A link on `page` of the paper, by its words.
        func link(_ text: String, in harness: M3Harness, page: Int = 0) throws -> PDFAnnotation {
            let annotations = harness.pdf.page(at: page)?.annotations ?? []
            return try #require(annotations.first { $0.type == "Link" && ReaderPDFView.text(of: $0) == text })
        }

        @Test func hoveringACitationDescribesTheCitedWork() throws {
            let harness = try M3Harness(try LinkFixture.arxivPaper())
            defer { harness.close() }
            harness.showFirstPage()
            let place = try snapshot(harness.view)
            harness.view.handleHover(at: harness.center(of: try link("Hamilton et al.", in: harness)))
            spin(timeout: 2) { harness.previews.current != nil }
            let preview = try #require(harness.previews.current)
            #expect(preview.trigger == .hover)
            let card = try #require(preview.citationCard)
            #expect(card.values[.title] == "Inductive representation learning on large graphs")
            #expect(card.values[.author] == "Will Hamilton, Zhitao Ying, and Jure Leskovec")
            #expect(card.values[.series] == "Advances in Neural Information Processing Systems")
            #expect(card.values[.year] == "2017")
            // What this entry doesn't give, and what no reference list gives.
            for field in [CitationCardView.Field.url, .keywords, .abstract] {
                #expect(card.values[field] == CitationCardView.missing, "\(field)")
            }
            #expect(card.urlButton == nil)
            // No page is shown, and the card is smaller than a page preview.
            #expect(preview.previewView.document == nil)
            #expect(preview.view.frame.width == LinkPreviewController.citationWidth)
            #expect(preview.view.frame.height > 150)
            #expect(preview.view.frame.height < LinkPreviewController.defaultSize.height)
            expectUnmoved(place, in: harness.view)
            #expect(harness.primary.history.isEmpty)
        }

        @Test func forceClickAndTheKeyboardShowTheCardToo() throws {
            let harness = try M3Harness(try LinkFixture.arxivPaper())
            defer { harness.close() }
            harness.showFirstPage()
            let annotation = try link("Kearnes et al.", in: harness)
            #expect(harness.view.previewLink(at: harness.center(of: annotation), trigger: .forceClick))
            #expect(harness.previews.current?.citationCard?.values[.title] == "Molecular graph convolutions: moving beyond fingerprints")
            harness.controller.dismissPreview()

            harness.view.beginLinkFocus()
            let index = try #require(harness.view.focusableLinks.firstIndex { $0.annotation === annotation })
            harness.view.moveLinkFocus(by: index)
            harness.view.previewFocusedLink()
            harness.view.endLinkFocus()
            let preview = try #require(harness.previews.current)
            #expect(preview.trigger == .keyboard)
            #expect(preview.citationCard?.values[.year] == "2016")
        }

        @Test func aCrossReferenceStillPreviewsItsPage() throws {
            let harness = try M3Harness(try LinkFixture.arxivPaper())
            defer { harness.close() }
            harness.view.restore(try #require(harness.view.topAnchor(forPageAt: 1)))
            Spin.runLoop(0.05)
            // "Section 3", linked by its number alone.
            let annotation = try link("3", in: harness, page: 1)
            #expect(harness.view.previewLink(at: harness.center(of: annotation), trigger: .forceClick))
            let preview = try #require(harness.previews.current)
            #expect(preview.citation == nil)
            #expect(preview.citationCard == nil)
            #expect(preview.previewView.document === harness.pdf)
            #expect(preview.previewView.visibleAnchor?.pageIndex == 4)
        }

        @Test func goFromTheCardGoesToTheEntryAndRecordsHistory() throws {
            let harness = try M3Harness(try LinkFixture.arxivPaper())
            defer { harness.close() }
            harness.showFirstPage()
            harness.view.previewLink(at: harness.center(of: try link("Hamilton et al.", in: harness)), trigger: .forceClick)
            let preview = try #require(harness.previews.current)
            #expect(preview.goButton.keyEquivalent == "\r", "Return is Go")
            #expect(preview.goButton.accessibilityLabel() == "Go to this reference")
            preview.go(nil)
            #expect(preview.isClosed)
            #expect(harness.controller.linkPreview == nil)
            #expect(harness.view.visibleAnchor?.pageIndex == 11)
            #expect(harness.primary.history.backList.count == 1)
        }

        @Test func theURLOpensOnlyThroughTheLinkPolicy() throws {
            let harness = try M3Harness(try LinkFixture.arxivPaper())
            defer { harness.close() }
            harness.showFirstPage()
            harness.view.previewLink(at: harness.center(of: try link("Kipf & Welling", in: harness)), trigger: .forceClick)
            let card = try #require(harness.previews.current?.citationCard)
            #expect(card.values[.title] == "Semi-Supervised Classification with Graph Convolutional Networks")
            let address = "https://openreview.net/forum?id=SJU4ayYgl"
            let button = try #require(card.urlButton)
            #expect(button.title == address)
            #expect(button.toolTip == address)
            #expect(harness.opener.opened.isEmpty, "nothing opens until it is clicked")
            button.performClick(nil)
            // Through the window's URL opener, never NSWorkspace directly (close() checks).
            #expect(harness.opener.opened == [URL(string: address)!])
        }

        @Test func theCardNamesItsFieldsForVoiceOver() throws {
            let harness = try M3Harness(try LinkFixture.arxivPaper())
            defer { harness.close() }
            harness.showFirstPage()
            harness.view.previewLink(at: harness.center(of: try link("Velickovic et al.", in: harness)), trigger: .forceClick)
            let preview = try #require(harness.previews.current)
            let card = try #require(preview.citationCard)
            #expect(preview.view.accessibilityLabel() == "Citation preview")
            #expect(card.accessibilityLabel() == "Cited work")
            // Each value is read with its field's name; the name column itself is skipped.
            for field in CitationCardView.Field.allCases where field != .url {
                #expect(card.valueViews[field]?.accessibilityLabel() == field.rawValue)
            }
            #expect(card.valueViews[.url] === card.urlButton)
            #expect(card.urlButton?.accessibilityLabel() == "Url: https://openreview.net/forum?id=rJXMpikCZ")
        }

        /// The real popover, once, sized to the card.
        @Test func theRealPopoverShowsTheCard() throws {
            let harness = try M3Harness(try LinkFixture.arxivPaper())
            defer { harness.close() }
            harness.showFirstPage()
            let annotation = try link("Gilmer et al.", in: harness)
            let destination = try #require(ReaderKit.LinkClassifier.target(of: annotation)?.destination)
            let work = try #require(harness.view.citationReader.work(citedBy: "Gilmer et al.", at: destination))
            let presenter = PopoverPreviewPresenter()
            presenter.animates = false
            let preview = LinkPreviewController(document: harness.pdf, destination: destination, linkText: "Gilmer et al.", citation: work)
            var closed = false
            preview.onClose = { closed = true }
            preview.onDismissRequest = { [weak presenter, weak preview] in
                guard let preview else { return }
                presenter?.dismiss(preview)
            }
            presenter.present(preview, relativeTo: NSRect(x: 100, y: 100, width: 50, height: 20), of: harness.view)
            preview.view.window?.alphaValue = 0
            preview.view.window?.ignoresMouseEvents = true
            let popover = try #require(presenter.currentPopover)
            #expect(popover.isShown)
            Spin.runLoop(0.1)
            // The whole card shows: the popover is as big as the card laid out inside it.
            #expect(abs(popover.contentSize.width - LinkPreviewController.citationWidth) < 1)
            #expect(abs(popover.contentSize.height - preview.view.fittingSize.height) < 1, "\(popover.contentSize) for \(preview.view.fittingSize)")
            // The card holds the focus, with no field selected, and Escape closes it.
            let popoverWindow = try #require(preview.view.window)
            #expect(popoverWindow.firstResponder === preview.view)
            Synth.key("\u{1b}", keyCode: 53, in: popoverWindow)
            spin(timeout: 3) { closed }
            #expect(closed)
            #expect(!popover.isShown)
        }
    }
}

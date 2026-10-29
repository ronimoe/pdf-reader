import AppKit
import PDFKit
import ReaderCore
import ReaderKit
import Testing
@testable import Lectern

extension M3Tests {
    /// A3 and Journey B: hover, Force Click and the keyboard open the same
    /// preview; the reader's place never changes unless they choose Go.
    @MainActor
    @Suite struct LinkPreview {
        // MARK: Triggers

        @Test func restingOnALinkForHalfASecondPreviewsIt() throws {
            let harness = try M3Harness()
            defer { harness.close() }
            harness.showFirstPage()
            let place = try #require(harness.view.currentAnchor)
            #expect(ReaderPDFView.hoverDelay == 0.5)
            harness.view.handleHover(at: harness.center(of: harness.link("Figure 3")))
            #expect(harness.view.isHoverPreviewPending)
            Spin.runLoop(0.25)
            #expect(harness.previews.presented.isEmpty, "not before the delay")
            spin(timeout: 2) { !harness.previews.presented.isEmpty }
            let preview = try #require(harness.previews.current)
            #expect(preview.trigger == .hover)
            #expect(preview.previewView.visibleAnchor?.pageIndex == 3)
            #expect(harness.view.currentAnchor == place)
            #expect(harness.primary.history.isEmpty)
        }

        @Test func leavingBeforeTheDelayPreviewsNothing() throws {
            let harness = try M3Harness()
            defer { harness.close() }
            harness.showFirstPage()
            harness.view.handleHover(at: harness.center(of: harness.link("Figure 3")))
            Spin.runLoop(0.2)
            harness.view.handleHover(at: CGPoint(x: 5, y: 5))
            Spin.runLoop(0.6)
            #expect(harness.previews.presented.isEmpty)
            // Only internal links preview on hover.
            harness.view.handleHover(at: harness.center(of: harness.link("Website")))
            Spin.runLoop(0.7)
            #expect(harness.previews.presented.isEmpty)
        }

        @Test func hoverPreviewsCanBeTurnedOffFromTheViewMenu() throws {
            let harness = try M3Harness()
            defer { harness.close() }
            harness.showFirstPage()
            let item = NSMenuItem(title: "", action: #selector(ReaderWindowController.togglePreviewLinksOnHover(_:)), keyEquivalent: "")
            #expect(harness.controller.validateMenuItem(item))
            #expect(item.state == .on, "on by default")
            harness.controller.togglePreviewLinksOnHover(nil)
            #expect(!harness.preferences.previewsLinksOnHover)
            #expect(!harness.view.previewsOnHover)
            _ = harness.controller.validateMenuItem(item)
            #expect(item.state == .off)
            harness.view.handleHover(at: harness.center(of: harness.link("Figure 3")))
            Spin.runLoop(0.7)
            #expect(harness.previews.presented.isEmpty)
            // The status line still says where the link goes.
            #expect(harness.controller.paneContainers[.primary]?.statusLine.text?.hasPrefix("Page 4") == true)
        }

        @Test func theFullURLShowsOnHover() throws {
            let harness = try M3Harness()
            defer { harness.close() }
            harness.showFirstPage()
            let status = try #require(harness.controller.paneContainers[.primary]?.statusLine)
            harness.view.handleHover(at: harness.center(of: harness.link("Website")))
            #expect(status.text == "https://lectern-probe.invalid/page")
            harness.view.handleHover(at: harness.center(of: harness.link("Other file")))
            #expect(status.text?.contains("another file") == true)
            harness.view.handleHover(at: nil)
            #expect(status.text == nil)
        }

        @Test func aHoverPreviewClosesWhenThePointerLeavesWithoutUsingIt() throws {
            let harness = try M3Harness()
            defer { harness.close() }
            harness.showFirstPage()
            harness.view.handleHover(at: harness.center(of: harness.link("Figure 3")))
            spin(timeout: 2) { harness.previews.current != nil }
            #expect(harness.previews.current != nil)
            harness.view.handleHover(at: CGPoint(x: 5, y: 5))
            spin(timeout: 2) { harness.previews.current == nil }
            #expect(harness.previews.current == nil)
            #expect(harness.controller.linkPreview == nil)
        }

        @Test func forceClickPreviewsAndTheReleaseDoesNotFollow() throws {
            let harness = try M3Harness()
            defer { harness.close() }
            harness.showFirstPage()
            let place = try #require(harness.view.currentAnchor)
            let point = harness.windowPoint(of: harness.link("Section 2"))
            harness.view.mouseDown(with: Synth.mouse(.leftMouseDown, at: point, in: harness.window))
            harness.view.handlePressureStage(1, at: harness.view.convert(point, from: nil))
            #expect(harness.previews.presented.isEmpty)
            harness.view.handlePressureStage(2, at: harness.view.convert(point, from: nil))
            let preview = try #require(harness.previews.current)
            #expect(preview.trigger == .forceClick)
            #expect(preview.previewView.visibleAnchor?.pageIndex == 4)
            harness.view.mouseUp(with: Synth.mouse(.leftMouseUp, at: point, in: harness.window))
            #expect(harness.view.currentAnchor == place)
            #expect(harness.primary.history.isEmpty)
            // A firm press on a web link neither previews nor opens.
            #expect(!harness.view.previewLink(at: harness.center(of: harness.link("Website")), trigger: .forceClick))
            #expect(harness.opener.opened.isEmpty)
        }

        // MARK: Keyboard link focus (Rule 8)

        @Test func optionTabCollectsTheVisibleLinksInReadingOrder() throws {
            let harness = try M3Harness()
            defer { harness.close() }
            harness.showFirstPage()
            harness.window.makeFirstResponder(harness.view)
            harness.key("\t", 48, .option)
            #expect(harness.view.isLinkFocusActive)
            let labels = harness.view.focusableLinks.map(\.label)
            let visible = LinkFixture.specs.prefix(labels.count)
            #expect(labels.count >= 8, "\(labels)")
            #expect(harness.view.focusableLinks.map { ReaderKit.LinkClassifier.target(of: $0.annotation)?.kind } == visible.map(\.kind))
            #expect(labels.first == "Link to Figure 3, page 4")
            #expect(labels.contains("Link to https://lectern-probe.invalid/page"))
            // The ring is drawn around the focused link.
            let ring = try #require(harness.view.subviews.first { String(describing: type(of: $0)) == "LinkFocusRingView" })
            #expect(!ring.isHidden)
            #expect(ring.frame.contains(harness.center(of: harness.link("Figure 3"))))
        }

        @Test func tabAndArrowsMoveSpacePreviewsReturnFollowsEscapeLeaves() throws {
            let harness = try M3Harness()
            defer { harness.close() }
            harness.showFirstPage()
            let place = try #require(harness.view.currentAnchor)
            harness.window.makeFirstResponder(harness.view)
            harness.key("\t", 48, .option)
            harness.key("\t", 48)
            #expect(harness.view.focusedLinkIndex == 1)
            harness.key("", 125)
            #expect(harness.view.focusedLinkIndex == 2)
            harness.key("", 126)
            harness.key("\t", 48, .shift)
            #expect(harness.view.focusedLinkIndex == 0)
            harness.key("\t", 48, .shift)
            #expect(harness.view.focusedLinkIndex == harness.view.focusableLinks.count - 1, "wraps")
            harness.key("\t", 48)
            // Space previews without moving the reader.
            harness.key(" ", 49)
            let preview = try #require(harness.previews.current)
            #expect(preview.trigger == .keyboard)
            #expect(preview.previewView.visibleAnchor?.pageIndex == 3)
            #expect(harness.view.currentAnchor == place)
            harness.controller.dismissPreview()
            // Escape leaves link focus.
            harness.key("\u{1b}", 53)
            #expect(!harness.view.isLinkFocusActive)
            // Return follows the focused link, with a history entry.
            harness.key("\t", 48, .option)
            harness.key("\r", 36)
            #expect(!harness.view.isLinkFocusActive)
            #expect(harness.view.visibleAnchor?.pageIndex == 3)
            #expect(harness.primary.history.backList.count == 1)
        }

        @Test func theFocusedWebLinkShowsItsURL() throws {
            let harness = try M3Harness()
            defer { harness.close() }
            harness.showFirstPage()
            harness.view.beginLinkFocus()
            let index = try #require(harness.view.focusableLinks.firstIndex { $0.target.url != nil })
            harness.view.moveLinkFocus(by: index)
            #expect(harness.controller.paneContainers[.primary]?.statusLine.text == "https://lectern-probe.invalid/page")
            harness.view.endLinkFocus()
            #expect(harness.controller.paneContainers[.primary]?.statusLine.text == nil)
        }

        @Test func focusedLinksAreAccessibilityElements() throws {
            let harness = try M3Harness()
            defer { harness.close() }
            harness.showFirstPage()
            harness.controller.focusLinks(nil)
            let children = harness.view.accessibilityChildren() ?? []
            let links = children.compactMap { $0 as? NSAccessibilityElement }.filter { $0.accessibilityRole() == .link }
            #expect(links.count == harness.view.focusableLinks.count)
            #expect(links.first?.accessibilityLabel() == "Link to Figure 3, page 4")
            #expect(links.allSatisfy { $0.accessibilityParent() as AnyObject? === harness.view })
            #expect(links.first?.accessibilityFrameInParentSpace().contains(harness.center(of: harness.link("Figure 3"))) == true)
            // PDFKit's own children (the page text) are still there.
            #expect(children.count > links.count)
            // VoiceOver's press follows the link.
            #expect(links[1].accessibilityPerformPress())
            #expect(harness.view.visibleAnchor?.pageIndex == 4)
        }

        // MARK: What the preview shows

        func preview(_ text: String, in harness: M3Harness) throws -> LinkPreviewController {
            harness.showFirstPage()
            harness.view.beginLinkFocus()
            let index = try #require(harness.view.focusableLinks.firstIndex { $0.annotation === harness.link(text) })
            harness.view.moveLinkFocus(by: index)
            harness.view.previewFocusedLink()
            harness.view.endLinkFocus()
            return try #require(harness.previews.current)
        }

        @Test func aPositionedDestinationIsScrolledToAndMarked() throws {
            let harness = try M3Harness()
            defer { harness.close() }
            let preview = try preview("Figure 3", in: harness)
            let view = preview.previewView
            #expect(view.zoomMode == .fitWidth)
            #expect(!preview.showsWholePage)
            let marker = try #require(view.targetMarker)
            #expect(marker.pageIndex == 3)
            #expect(abs(marker.pointInPage.y - 500) < 1)
            // The target line is on screen, near the top.
            let page = try #require(view.document?.page(at: 3))
            let target = view.convert(CGPoint(x: 100, y: 500), from: page)
            #expect(view.bounds.contains(target))
            #expect(target.y > view.bounds.midY)
            let markerView = try #require(view.subviews.first { String(describing: type(of: $0)) == "TargetMarkerView" })
            #expect(!markerView.isHidden)
            #expect(markerView.frame.intersects(view.bounds))
            #expect(preview.titleLabel.stringValue == "Figure 3 — Page 4")
        }

        @Test(arguments: ["Appendix", "Fit width", "Fit rectangle", "No position"])
        func destinationsWithoutAPositionShowTheWholePage(text: String) throws {
            let harness = try M3Harness()
            defer { harness.close() }
            let preview = try preview(text, in: harness)
            let view = preview.previewView
            #expect(preview.showsWholePage)
            #expect(view.zoomMode == .fitPage)
            #expect(view.targetMarker == nil)
            let destination = preview.destination
            let page = try #require(destination.page)
            let rect = view.convert(page.bounds(for: view.displayBox), from: page)
            #expect(view.bounds.insetBy(dx: -2, dy: -2).contains(rect), "\(rect) in \(view.bounds)")
        }

        @Test func linksInsideThePreviewMoveItWithItsOwnBack() throws {
            let harness = try M3Harness()
            defer { harness.close() }
            let preview = try preview("Section 2", in: harness)
            let place = try #require(harness.view.currentAnchor)
            #expect(preview.backButton.isHidden)
            let view = preview.previewView
            let back = try #require(view.document?.page(at: 4)?.annotations.first { $0.bounds.minY == 100 })
            // Scroll the preview down to that link, as the user would.
            view.restore(ReadingAnchor(pageIndex: 4, pointInPage: CGPoint(x: 0, y: 200), scale: 1))
            // A click inside the preview, through the same interception.
            let point = view.convert(CGPoint(x: back.bounds.midX, y: back.bounds.midY), from: back.page!)
            #expect(view.bounds.contains(point), "the link is visible in the preview")
            view.mouseDown(with: Synth.mouse(.leftMouseDown, at: view.convert(point, to: nil), in: view.window!))
            view.mouseUp(with: Synth.mouse(.leftMouseUp, at: view.convert(point, to: nil), in: view.window!))
            #expect(preview.destination.page?.document?.index(for: preview.destination.page!) == 0)
            #expect(view.visibleAnchor?.pageIndex == 0)
            #expect(!preview.backButton.isHidden)
            preview.goBackInPreview(nil)
            #expect(view.visibleAnchor?.pageIndex == 4)
            #expect(preview.backButton.isHidden)
            // The reader's pane and its history never moved.
            #expect(harness.view.currentAnchor == place)
            #expect(harness.primary.history.isEmpty)
        }

        @Test func goNavigatesTheReaderAndRecordsHistory() throws {
            let harness = try M3Harness()
            defer { harness.close() }
            let preview = try preview("Table 1", in: harness)
            let place = try #require(harness.view.currentAnchor)
            #expect(preview.goButton.keyEquivalent == "\r", "Return is Go")
            preview.go(nil)
            #expect(preview.isClosed)
            #expect(harness.view.visibleAnchor?.pageIndex == 5)
            #expect(harness.primary.history.backList.count == 1)
            harness.controller.navigateBack(nil)
            #expect(harness.view.currentAnchor?.isSamePlace(as: place) == true)
        }

        @Test func dismissingLeavesThePlaceExactlyWhereItWas() throws {
            let harness = try M3Harness()
            defer { harness.close() }
            harness.showFirstPage()
            harness.view.restore(ReadingAnchor(pageIndex: 0, pointInPage: CGPoint(x: 0, y: 620), scale: 1))
            let place = try #require(harness.view.currentAnchor)
            harness.view.beginLinkFocus()
            harness.view.previewFocusedLink()
            harness.view.endLinkFocus()
            let preview = try #require(harness.previews.current)
            // Escape in the preview.
            preview.previewView.cancelOperation(nil)
            #expect(preview.isClosed)
            #expect(harness.controller.linkPreview == nil)
            #expect(harness.view.currentAnchor == place)
            #expect(harness.primary.history.isEmpty)
        }

        /// The real popover, once: shown on the invisible window, made
        /// invisible itself before it can draw, then closed.
        @Test func theRealPopoverShowsAndCloses() throws {
            let harness = try M3Harness()
            defer { harness.close() }
            harness.showFirstPage()
            let presenter = PopoverPreviewPresenter()
            presenter.animates = false
            let preview = LinkPreviewController(document: harness.pdf, destination: try #require(harness.link("Figure 3").destination ?? (harness.link("Figure 3").action as? PDFActionGoTo)?.destination))
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
            #expect(popover.behavior == .transient)
            spin(timeout: 2) { preview.previewView.visibleAnchor?.pageIndex == 3 }
            #expect(preview.previewView.visibleAnchor?.pageIndex == 3)
            preview.dismiss()
            spin(timeout: 3) { closed }
            #expect(closed)
            #expect(!popover.isShown)
        }
    }
}

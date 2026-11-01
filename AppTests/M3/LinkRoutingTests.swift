import AppKit
import PDFKit
import ReaderCore
import ReaderKit
import Testing
@testable import Lectern

extension M3Tests {
    /// A4 and architecture §4.4: every link is classified by action type and
    /// routed by our code; PDFKit never acts on one, and nothing opens a URL
    /// except through the opener seam.
    @MainActor
    @Suite struct LinkRouting {
        @Test func everyFixtureLinkIsClassifiedByItsActionType() throws {
            let document = try #require(PDFDocument(data: LinkFixture.make()))
            let links = try #require(document.page(at: 0)).annotations.filter { $0.type == "Link" }
            #expect(links.count == LinkFixture.specs.count)
            for spec in LinkFixture.specs {
                let annotation = try #require(links.first { $0.bounds.intersects(LinkFixture.rect(LinkFixture.index(spec.text)).insetBy(dx: 4, dy: 4)) })
                #expect(ReaderKit.LinkClassifier.target(of: annotation)?.kind == spec.kind, "\(spec.text)")
            }
            // Launch arrives as a URL action with no URL; it is still blocked.
            let launch = try #require(links.first { $0.action?.type == "Launch" })
            #expect(launch.action is PDFActionURL)
            #expect(ReaderKit.LinkClassifier.target(of: launch)?.kind == "blocked(Launch)")
        }

        @Test func clickingAnInternalLinkJumpsAndBackReturns() throws {
            let harness = try M3Harness()
            defer { harness.close() }
            harness.showFirstPage()
            let before = try snapshot(harness.view)
            harness.click(harness.link("Figure 3"))
            #expect(harness.view.visibleAnchor?.pageIndex == 3)
            #expect(harness.primary.history.backList.count == 1)
            // It landed on the destination's point, /XYZ 72 500.
            #expect(abs((harness.view.visibleAnchor?.pointInPage.y ?? 0) - 500) < 2)
            harness.controller.navigateBack(nil)
            expectUnmoved(before, in: harness.view)
        }

        @Test func namedDestinationsResolveAndJump() throws {
            let harness = try M3Harness()
            defer { harness.close() }
            harness.showFirstPage()
            harness.click(harness.link("Section 2"))
            #expect(harness.view.visibleAnchor?.pageIndex == 4)
            // From there, the GoTo action naming "tab1".
            harness.view.perform(try #require(harness.link("Table 1").action))
            #expect(harness.view.visibleAnchor?.pageIndex == 5)
            #expect(harness.primary.history.backList.map(\.pageIndex) == [0, 4])
        }

        @Test func fitDestinationsLandOnThePageTop() throws {
            let harness = try M3Harness()
            defer { harness.close() }
            harness.showFirstPage()
            harness.click(harness.link("Appendix"))
            let anchor = try #require(harness.view.visibleAnchor)
            #expect(anchor.pageIndex == 2)
            #expect(anchor.pointInPage.y > 780)
        }

        @Test func aWebLinkOpensOnlyThroughTheOpener() throws {
            let harness = try M3Harness()
            defer { harness.close() }
            harness.showFirstPage()
            let before = try snapshot(harness.view)
            harness.click(harness.link("Website"))
            #expect(harness.opener.opened == [URL(string: "https://lectern-probe.invalid/page")!])
            #expect(harness.presenter.confirmations.isEmpty)
            #expect(harness.primary.history.isEmpty)
            expectUnmoved(before, in: harness.view)
        }

        /// A double-click follows the link once, as a browser does: each
        /// click of the pair reaches `mouseUp`, the second with a click count of 2.
        @Test(arguments: ["Website", "Launch app"])
        func aDoubleClickFollowsALinkOnce(text: String) throws {
            let harness = try M3Harness()
            defer { harness.close() }
            harness.showFirstPage()
            var activations = 0
            let route = harness.view.onActivateLink
            harness.view.onActivateLink = { target in
                activations += 1
                route?(target)
            }
            let point = harness.windowPoint(of: harness.link(text))
            for clickCount in 1...2 {
                harness.view.mouseDown(with: Synth.mouse(.leftMouseDown, at: point, in: harness.window, clickCount: clickCount))
                harness.view.mouseUp(with: Synth.mouse(.leftMouseUp, at: point, in: harness.window, clickCount: clickCount))
            }
            Spin.runLoop(0.1)
            #expect(activations == 1)
            #expect(harness.opener.opened.count + harness.presenter.blockedLinks.count == 1)
        }

        @Test func anyOtherSchemeAsksFirstAndShowsTheURL() throws {
            let harness = try M3Harness()
            defer { harness.close() }
            harness.showFirstPage()
            harness.click(harness.link("Custom scheme"))
            let url = URL(string: "lectern-probe-unhandled://uri-link")!
            #expect(harness.presenter.confirmations == [url])
            #expect(harness.opener.opened.isEmpty, "nothing opens before the user confirms")
            harness.presenter.confirmOpen?()
            #expect(harness.opener.opened == [url])
        }

        @Test(arguments: ["Other file", "Launch app", "Run script", "Submit form"])
        func blockedLinksExplainAndDoNothing(text: String) throws {
            let harness = try M3Harness()
            defer { harness.close() }
            harness.showFirstPage()
            let before = try snapshot(harness.view)
            harness.click(harness.link(text))
            let expected = String(LinkFixture.specs[LinkFixture.index(text)].kind.dropFirst("blocked(".count).dropLast())
            #expect(harness.presenter.blockedLinks.map(\.actionType) == [expected])
            #expect(!harness.presenter.blockedLinks[0].message.isEmpty)
            #expect(harness.opener.opened.isEmpty)
            #expect(harness.primary.history.isEmpty)
            expectUnmoved(before, in: harness.view)
        }

        @Test func aNamedNextPageLinkMovesOnePageWithHistory() throws {
            let harness = try M3Harness()
            defer { harness.close() }
            harness.showFirstPage()
            harness.click(harness.link("Next page"))
            #expect(harness.view.visibleAnchor?.pageIndex == 1)
            #expect(harness.primary.history.backList.count == 1)
        }

        /// The catch-all: every path that ends in `perform(_:)` (VoiceOver,
        /// keyboard, paths not anticipated) routes the same way, and PDFKit's
        /// own handling never runs.
        @Test func performIsAChokePointForEveryAction() throws {
            let harness = try M3Harness()
            defer { harness.close() }
            harness.showFirstPage()
            for spec in LinkFixture.specs {
                harness.showFirstPage()
                let action = try #require(harness.link(spec.text).action)
                harness.view.perform(action)
            }
            #expect(harness.opener.opened.map(\.absoluteString) == ["https://lectern-probe.invalid/page"])
            #expect(harness.presenter.confirmations.count == 1)
            #expect(harness.presenter.blockedLinks.map(\.actionType) == ["GoToR", "Launch", "JavaScript", "SubmitForm"])
            // Every jump departed from the top of page 1, so history holds it
            // once; the last action, NextPage, left the reader on page 2.
            #expect(harness.primary.history.backList.map(\.pageIndex) == [0])
            #expect(harness.view.visibleAnchor?.pageIndex == 1)
        }

        @Test func pdfKitsSideDoorsAreClosed() throws {
            let harness = try M3Harness()
            defer { harness.close() }
            let view = harness.view
            // The delegate's URL callback routes through the policy.
            #expect(view.delegate != nil)
            view.delegate?.pdfViewWillClick?(onLink: view, with: URL(string: "lectern-probe-unhandled://delegate")!)
            #expect(harness.presenter.confirmations.map(\.absoluteString) == ["lectern-probe-unhandled://delegate"])
            // The private "Open Link" action routes through it too.
            let item = NSMenuItem(title: "Open Link", action: ReaderPDFView.openRepresentedLinkSelector, keyEquivalent: "")
            item.representedObject = URL(string: "https://lectern-probe.invalid/menu")!
            view.perform(ReaderPDFView.openRepresentedLinkSelector, with: item)
            #expect(harness.opener.opened.map(\.absoluteString) == ["https://lectern-probe.invalid/menu"])
            // No "Open Link" in the context menu, even after AppKit adds its items.
            let event = Synth.mouse(.rightMouseDown, at: harness.windowPoint(of: harness.link("Website")), in: harness.window)
            let menu = try #require(view.menu(for: event))
            // As PDFKit would add it while the menu opens.
            menu.addItem(withTitle: "Open Link", action: ReaderPDFView.openRepresentedLinkSelector, keyEquivalent: "")
            #expect(menu.items.contains { $0.action == ReaderPDFView.openRepresentedLinkSelector })
            view.willOpenMenu(menu, with: event)
            #expect(!menu.items.contains { $0.action == ReaderPDFView.openRepresentedLinkSelector })
            // PDFKit's Force Click recognizer is gone, and stays gone.
            #expect(!view.gestureRecognizers.contains { ReaderPDFView.isImmediateAction($0) })
            #expect(view.pressureConfiguration != nil)
        }

        @Test func aLinkClickFocusesItsPane() throws {
            let harness = try M3Harness()
            defer { harness.close() }
            harness.controller.openSplit(at: harness.view.topAnchor(forPageAt: 0))
            let secondary = try #require(harness.controller.secondaryPane)
            harness.window.makeFirstResponder(harness.view)
            #expect(harness.controller.focusedPaneID == .primary)
            harness.showFirstPage(in: secondary)
            harness.click(harness.link("Next page"), in: secondary.view)
            #expect(harness.controller.focusedPaneID == .secondary)
            #expect(secondary.history.backList.count == 1)
            #expect(harness.primary.history.isEmpty)
        }
    }
}

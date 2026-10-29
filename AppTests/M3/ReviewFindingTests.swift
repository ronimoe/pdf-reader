import AppKit
import PDFKit
import Persistence
import ReaderCore
import ReaderKit
import Testing
@testable import Lectern

/// Tests for the PR #11 review findings.
extension M3Tests.LinkRouting {
    /// A `file:` link, or any URL that opens something on this Mac, is a
    /// Launch action in disguise: blocked, never offered for confirmation.
    @Test func localFileAndAppURLsAreBlockedAsLaunch() throws {
        let launches = [
            "file:///Applications/Calculator.app", "file:///etc/hosts", "FILE:///tmp/lectern-probe",
            "smb://lectern-probe.invalid/share", "afp://lectern-probe.invalid/share", "ssh://lectern-probe.invalid",
            "/Applications/Calculator.app", "lectern-probe.pdf",
        ]
        for string in launches {
            let url = try #require(URL(string: string))
            #expect(ReaderKit.LinkClassifier.target(of: url).kind == "blocked(Launch)", "\(string)")
        }
        // Through a URI action, as a document carries it.
        let action = PDFActionURL(url: try #require(URL(string: "file:///Applications/Calculator.app")))
        #expect(ReaderKit.LinkClassifier.target(of: action).kind == "blocked(Launch)")
        // The explanation is the Launch one.
        #expect(BlockedLink(actionType: "Launch").title == "This link would open an app or file")
        // Web links and other remote schemes are unchanged.
        #expect(ReaderKit.LinkClassifier.target(of: try #require(URL(string: "https://lectern-probe.invalid"))).kind == "web(https://lectern-probe.invalid)")
        #expect(ReaderKit.LinkClassifier.target(of: try #require(URL(string: "mailto:probe@lectern-probe.invalid"))).kind.hasPrefix("otherScheme("))
    }

    /// PDFKit doesn't route a document's /OpenAction through `perform(_:)`
    /// when the document is shown, so opening a file never follows a link or
    /// makes a history entry. Checked on a view in an on-screen window.
    @Test func showingADocumentNeverPerformsItsOpenAction() throws {
        let view = ReaderPDFView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        var activated: [String] = []
        view.onActivateLink = { activated.append($0.kind) }
        let host = OffscreenHost(content: view, size: NSSize(width: 600, height: 800))
        defer { host.close() }
        view.show(PDFDocument(data: LinkFixture.make(openAction: "[8 0 R /Fit]")))
        view.layoutDocumentView()
        Spin.runLoop(0.3)
        #expect(activated.isEmpty)
        #expect(view.visibleAnchor?.pageIndex == 0)
    }
}

extension M3Tests.LinkPreview {
    /// Look Up (Force Click, three-finger tap) over any link is handled by
    /// the reader: internal links preview, and nothing reaches PDFKit.
    @Test func lookUpOverAnyLinkNeverReachesPDFKit() throws {
        let harness = try M3Harness()
        defer { harness.close() }
        harness.showFirstPage()
        let view = harness.view
        for text in ["Website", "Custom scheme", "Other file", "Launch app", "Next page"] {
            #expect(view.handleLookUpOverLink(at: harness.center(of: harness.link(text))), "\(text)")
        }
        #expect(harness.previews.presented.isEmpty)
        #expect(harness.opener.opened.isEmpty)
        #expect(harness.presenter.confirmations.isEmpty && harness.presenter.blockedLinks.isEmpty)
        // Plain page area: left to PDFKit's Look Up.
        let page = try #require(harness.pdf.page(at: 0))
        #expect(!view.handleLookUpOverLink(at: view.convert(CGPoint(x: 450, y: 400), from: page)))
        // An internal link previews.
        #expect(view.handleLookUpOverLink(at: harness.center(of: harness.link("Figure 3"))))
        #expect(harness.previews.current?.trigger == .forceClick)
    }
}

extension M3Tests.SplitView {
    /// Each pane keeps its own zoom: only the first pane's is the document's
    /// zoom, the second's is stored with the split, and the View menu's
    /// checkmarks follow the focused pane.
    @Test func eachPaneKeepsItsOwnZoomAcrossReopen() throws {
        let folder = try TemporaryFolder()
        let file = try folder.write(FixturePDF.prose(pages: 12), to: "zoom.pdf")
        let store = folder.store()
        let first = try M3Harness(file: file, store: store)
        let leftZoom = first.view.zoomMode
        #expect(leftZoom != .actualSize)
        first.controller.openSplit()
        let right = try #require(first.controller.secondaryPane)
        first.controller.focusOtherPane(nil)
        first.controller.zoomToActualSize(nil)
        #expect(right.view.zoomMode == .actualSize)
        #expect(first.view.zoomMode == leftZoom)
        #expect(first.controller.settings.zoom == leftZoom)

        func checked(_ action: Selector) -> Bool {
            let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
            _ = first.controller.validateMenuItem(item)
            return item.state == .on
        }
        #expect(checked(#selector(ReaderWindowController.zoomToActualSize(_:))))
        first.controller.focusOtherPane(nil)
        #expect(!checked(#selector(ReaderWindowController.zoomToActualSize(_:))))
        #expect(checked(#selector(ReaderWindowController.zoomToFitWidth(_:))) == (leftZoom == .fitWidth))

        first.controller.saveStateNow()
        first.close()
        let second = try M3Harness(file: file, store: store)
        defer { second.close() }
        #expect(second.view.zoomMode == leftZoom, "the left pane keeps its own zoom")
        #expect(second.controller.secondaryPane?.view.zoomMode == .actualSize)
    }

    /// Re-binding after an annotation change keeps the page the fit modes
    /// measure: on a document of mixed page sizes a Fit Width pane keeps its
    /// scale.
    @Test func reBindingKeepsTheFitReferencePage() throws {
        let harness = try M3Harness(LinkFixture.mixedSizes())
        defer { harness.close() }
        let controller = harness.controller
        controller.openSplit()
        var scales: [CGFloat] = []
        for pane in controller.panes {
            let wide = try #require(harness.pdf.page(at: 1))
            pane.view.go(to: wide)
            pane.view.restore(try #require(pane.view.topAnchor(forPageAt: 1)))
            Spin.runLoop(0.05)
            pane.view.setZoomMode(.fitWidth)
            // Fitted to the wide page, not the narrow first one.
            #expect(pane.view.scaleFactor * 1224 <= pane.view.bounds.width + 2)
            scales.append(pane.view.scaleFactor)
        }
        controller.notifyAnnotationsChanged(from: harness.primary)
        Spin.runLoop(0.1)
        for (pane, scale) in zip(controller.panes, scales) {
            #expect(abs(pane.view.scaleFactor - scale) < 0.001, "\(pane.id)")
        }
    }
}

extension M3Tests {
    /// The window's content runs under the toolbar, but a document starts
    /// with the top edge of page 1 visible just below it.
    @MainActor
    @Suite struct ContentBelowTheToolbar {
        @Test func pageOnesTopEdgeIsVisibleAtTheTopOfADocument() throws {
            let harness = try M3Harness(FixturePDF.prose(pages: 5))
            defer { harness.close() }
            let view = harness.view
            let insets = view.safeAreaInsets
            #expect(insets.top > 0, "the toolbar covers the top of the view")
            let page = try #require(harness.pdf.page(at: 0))
            let box = page.bounds(for: view.displayBox)
            let top = view.convert(CGPoint(x: box.midX, y: box.maxY), from: page)
            let visible = NSRect(x: insets.left, y: insets.bottom, width: view.bounds.width - insets.left - insets.right, height: view.bounds.height - insets.top - insets.bottom)
            #expect(visible.insetBy(dx: 0, dy: -0.5).contains(top), "\(top) in \(visible)")
            #expect(top.y >= visible.maxY - 30, "just below the toolbar")
            // The same holds after scrolling away and back to the top.
            harness.view.restore(try #require(view.topAnchor(forPageAt: 3)))
            harness.view.restore(try #require(view.topAnchor(forPageAt: 0)))
            let again = view.convert(CGPoint(x: box.midX, y: box.maxY), from: page)
            #expect(visible.insetBy(dx: 0, dy: -0.5).contains(again))
        }
    }
}

extension LinkFixture {
    /// Three pages: letter, a double-width page, letter.
    static func mixedSizes() -> Data {
        var objects: [Int: String] = [:]
        objects[1] = "<< /Type /Catalog /Pages 2 0 R >>"
        objects[2] = "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>"
        let widths = [612, 1224, 612]
        for (index, width) in widths.enumerated() {
            objects[3 + index] = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(width) 792] /Contents \(6 + index) 0 R /Resources << /Font << /F1 9 0 R >> >> >>"
            objects[6 + index] = SpikeRawPDF.textContent(["Page \(index + 1), \(width) points wide"])
        }
        objects[9] = SpikeRawPDF.helvetica
        return SpikeRawPDF.build(objects: objects, root: 1).data
    }
}

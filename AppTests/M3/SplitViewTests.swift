import AppKit
import PDFKit
import Persistence
import ReaderCore
import ReaderKit
import Testing
@testable import Lectern

extension M3Tests {
    /// B3: one document in two equal panes, each with its own history; the
    /// sidebar, search, Go to Page and Back and Forward act on the focused one.
    @MainActor
    @Suite struct SplitView {
        @Test func theSplitHasTwoEqualPanesOnOneDocument() throws {
            let harness = try M3Harness()
            defer { harness.close() }
            let item = NSMenuItem(title: "", action: #selector(ReaderWindowController.toggleSplitView(_:)), keyEquivalent: "")
            _ = harness.controller.validateMenuItem(item)
            #expect(item.title == "Split View")
            harness.controller.toggleSplitView(nil)
            let secondary = try #require(harness.controller.secondaryPane)
            #expect(secondary.view.document === harness.view.document)
            let primaryWidth = try #require(harness.controller.paneContainers[.primary]).frame.width
            let secondaryWidth = try #require(harness.controller.paneContainers[.secondary]).frame.width
            #expect(abs(primaryWidth - secondaryWidth) <= 2, "\(primaryWidth) vs \(secondaryWidth)")
            // It opens at the same place, with focus staying where it was.
            #expect(secondary.view.visibleAnchor?.pageIndex == harness.view.visibleAnchor?.pageIndex)
            #expect(harness.controller.focusedPaneID == .primary)
            _ = harness.controller.validateMenuItem(item)
            #expect(item.title == "Close Split View")
        }

        @Test func theFocusedPaneHasACalmIndicatorAndBothCanClose() throws {
            let harness = try M3Harness()
            defer { harness.close() }
            let primary = try #require(harness.controller.paneContainers[.primary])
            #expect(!primary.showsFocus && primary.closeButton.isHidden, "no split chrome on a single pane")
            harness.controller.openSplit()
            let secondary = try #require(harness.controller.paneContainers[.secondary])
            #expect(primary.showsFocus)
            #expect(!secondary.showsFocus)
            #expect(!primary.closeButton.isHidden && !secondary.closeButton.isHidden)
            #expect(primary.accessibilityValue() as? String == "focused")
            harness.window.makeFirstResponder(harness.controller.secondaryPane!.view)
            #expect(harness.controller.focusedPaneID == .secondary)
            #expect(secondary.showsFocus && !primary.showsFocus)
            secondary.closeButton.performClick(nil)
            #expect(!harness.controller.isSplit)
            #expect(harness.controller.focusedPaneID == .primary)
        }

        @Test func theSidebarGoToPageAndHistoryActOnTheFocusedPane() throws {
            let harness = try M3Harness()
            defer { harness.close() }
            let controller = harness.controller
            controller.openSplit()
            let secondary = try #require(controller.secondaryPane)
            controller.focusOtherPane(nil)
            #expect(controller.focusedPaneID == .secondary)
            let primaryPlace = try snapshot(harness.view)

            // Outline (the sidebar) moves the focused pane only.
            controller.outlineSection.onJump?(try #require(harness.pdf.outlineRoot?.child(at: 1)))
            #expect(secondary.view.visibleAnchor?.pageIndex == 3)
            // Go to Page too.
            controller.showGoToPage(nil)
            let prompt = try #require(harness.presenter.goToPagePrompts.last)
            prompt.input = "5"
            prompt.submit()
            #expect(secondary.view.visibleAnchor?.pageIndex == 4)
            #expect(secondary.history.backList.map(\.pageIndex) == [0, 3])
            // Back acts on the focused pane.
            controller.navigateBack(nil)
            #expect(secondary.view.visibleAnchor?.pageIndex == 3)
            expectUnmoved(primaryPlace, in: harness.view)
            #expect(harness.primary.history.isEmpty)
            // Focus back on the first pane: its own, empty history.
            controller.focusOtherPane(nil)
            let back = NSMenuItem(title: "", action: #selector(ReaderWindowController.navigateBack(_:)), keyEquivalent: "")
            #expect(!controller.validateMenuItem(back))
        }

        @Test func searchActsOnTheFocusedPane() throws {
            let harness = try M3Harness()
            defer { harness.close() }
            let controller = harness.controller
            controller.openSplit()
            let secondary = try #require(controller.secondaryPane)
            controller.focusOtherPane(nil)
            controller.startSearch("line 7")
            spin { (controller.search?.results.count ?? 0) >= 3 && controller.search?.isSearching == false }
            controller.showNextResult(nil)
            controller.showNextResult(nil)
            #expect(secondary.view.currentSelection != nil)
            #expect(harness.view.currentSelection == nil)
            #expect(secondary.history.backList.count == 1)
            #expect(harness.primary.history.isEmpty)
            controller.endSearch()
        }

        @Test func openInSplitCreatesTheSplitAtTheDestination() throws {
            let harness = try M3Harness()
            defer { harness.close() }
            harness.showFirstPage()
            let place = try snapshot(harness.view)
            harness.view.beginLinkFocus()
            harness.view.previewFocusedLink()
            harness.view.endLinkFocus()
            let preview = try #require(harness.previews.current)
            preview.openInSplit(nil)
            #expect(preview.isClosed)
            let secondary = try #require(harness.controller.secondaryPane)
            #expect(secondary.view.visibleAnchor?.pageIndex == 3)
            // The reader stays put, in the focused first pane (the pane is
            // narrower now, so only the scale differs).
            expectUnmoved(place, in: harness.view, resized: true)
            #expect(harness.controller.focusedPaneID == .primary)
            #expect(harness.primary.history.isEmpty)
        }

        @Test func openInSplitMovesTheOtherPaneAndRecordsItThere() throws {
            let harness = try M3Harness()
            defer { harness.close() }
            harness.controller.openSplit()
            let secondary = try #require(harness.controller.secondaryPane)
            secondary.view.restore(try #require(secondary.view.topAnchor(forPageAt: 6)))
            harness.showFirstPage()
            let place = try snapshot(harness.view)
            try harness.preview(harness.link("Section 2")).openInSplit(nil)
            #expect(secondary.view.visibleAnchor?.pageIndex == 4)
            #expect(secondary.history.backList.map(\.pageIndex) == [6])
            expectUnmoved(place, in: harness.view)
            #expect(harness.primary.history.isEmpty)
            // From the second pane, the first one is "the other".
            harness.controller.focusOtherPane(nil)
            try harness.preview(harness.link("Figure 3"), from: secondary).openInSplit(nil)
            #expect(harness.view.visibleAnchor?.pageIndex == 3)
            #expect(harness.primary.history.backList.count == 1)
        }

        @Test func closingTheFirstPaneKeepsTheSecondsPlaceAndHistory() throws {
            let harness = try M3Harness()
            defer { harness.close() }
            harness.controller.openSplit()
            let secondary = try #require(harness.controller.secondaryPane)
            secondary.jump(toPageAt: 5)
            let place = try #require(secondary.view.currentAnchor)
            let history = secondary.history
            harness.controller.closePane(.primary)
            #expect(!harness.controller.isSplit)
            #expect(harness.primary.history == history)
            expectKeptPlace(place, in: harness.view)
        }

        @Test func layoutRotationAndZoomKeepBothPanesPlaces() throws {
            let harness = try M3Harness(FixturePDF.prose(pages: 12))
            defer { harness.close() }
            let controller = harness.controller
            controller.openSplit()
            let secondary = try #require(controller.secondaryPane)
            harness.view.restore(ReadingAnchor(pageIndex: 2, pointInPage: CGPoint(x: 0, y: 500), scale: 1))
            secondary.view.restore(ReadingAnchor(pageIndex: 8, pointInPage: CGPoint(x: 0, y: 400), scale: 1))
            let first = try #require(harness.view.currentAnchor)
            let second = try #require(secondary.view.currentAnchor)
            controller.showTwoPages(nil)
            controller.rotateDocumentRight(nil)
            controller.showSinglePage(nil)
            controller.rotateDocumentLeft(nil)
            expectKeptPlace(first, in: harness.view)
            expectKeptPlace(second, in: secondary.view)
            // Zoom acts on the focused pane only.
            let scale = secondary.view.scaleFactor
            controller.increaseZoom(nil)
            #expect(abs(secondary.view.scaleFactor - scale) < 0.001)
            expectKeptPlace(second, in: secondary.view)
        }

        @Test func theSplitAndEachPanesPlaceAndHistoryComeBackOnReopen() throws {
            let folder = try TemporaryFolder()
            let file = try folder.write(FixturePDF.prose(pages: 12), to: "split.pdf")
            let store = folder.store()
            let first = try M3Harness(file: file, store: store)
            first.primary.jump(toPageAt: 3)
            first.controller.openSplit()
            let secondary = try #require(first.controller.secondaryPane)
            secondary.jump(toPageAt: 9)
            first.controller.focusOtherPane(nil)
            let places = (try #require(first.view.currentAnchor), try #require(secondary.view.currentAnchor))
            let histories = (first.primary.history, secondary.history)
            first.controller.saveStateNow()
            first.close()

            let second = try M3Harness(file: file, store: store)
            let restored = try #require(second.controller.secondaryPane)
            #expect(second.controller.focusedPaneID == .secondary)
            expectKeptPlace(places.0, in: second.view)
            expectKeptPlace(places.1, in: restored.view)
            #expect(second.primary.history == histories.0)
            #expect(restored.history == histories.1)
            // Closing the split is remembered too.
            second.controller.toggleSplitView(nil)
            second.controller.saveStateNow()
            second.close()
            let third = try M3Harness(file: file, store: store)
            defer { third.close() }
            #expect(!third.controller.isSplit)
            #expect(store.open(url: file, data: try Data(contentsOf: file), pageCount: 12).state.history[.secondary] == nil)
        }

        /// M0b Q7: a live annotation change shows only in the pane that last
        /// laid the page out. After `notifyAnnotationsChanged(from:)` every
        /// pane shows it, in place, again and again.
        @Test func annotationChangesReachBothPanes() throws {
            let harness = try M3Harness(FixturePDF.prose(pages: 6))
            defer { harness.close() }
            let controller = harness.controller
            controller.openSplit()
            let secondary = try #require(controller.secondaryPane)
            harness.view.restore(ReadingAnchor(pageIndex: 0, pointInPage: CGPoint(x: 0, y: 600), scale: 1))
            secondary.view.restore(ReadingAnchor(pageIndex: 0, pointInPage: CGPoint(x: 0, y: 500), scale: 1))
            Spin.runLoop(0.3)
            let places = (try #require(harness.view.currentAnchor), try #require(secondary.view.currentAnchor))
            let page = try #require(harness.pdf.page(at: 0))
            var timings: [Double] = []
            for round in 1...3 {
                let source = round == 2 ? secondary : harness.primary
                let highlight = PDFAnnotation(bounds: CGRect(x: 72, y: 600 - CGFloat(round) * 40, width: 200, height: 16), forType: .highlight, withProperties: nil)
                page.addAnnotation(highlight)
                Spin.runLoop(0.2)
                let start = monotonicSeconds()
                controller.notifyAnnotationsChanged(from: source)
                timings.append(monotonicSeconds() - start)
                Spin.runLoop(0.3)
                #expect(annotationLayerCount(harness.view) == round, "first pane, round \(round)")
                #expect(annotationLayerCount(secondary.view) == round, "second pane, round \(round)")
                expectKeptPlace(places.0, in: harness.view)
                expectKeptPlace(places.1, in: secondary.view)
            }
            let report = "notifyAnnotationsChanged re-bind times (s): \(timings.map { String(format: "%.4f", $0) })"
            SpikeLog.note("M3", report)
            // Also in the test host's temporary folder, as test stdout isn't always kept.
            try? Data(report.utf8).write(to: FileManager.default.temporaryDirectory.appending(path: "m3-rebind-timings.txt"))
            #expect(timings.max() ?? 1 < 0.25)
        }
    }

    /// Real arXiv paper (CC BY 4.0): its linksInside links resolve, route and
    /// preview, and previewing never moves the reader.
    @MainActor
    @Suite struct RealPaper {
        @Test func internalLinksResolveAndPreview() throws {
            let harness = try M3Harness(try LinkFixture.arxivPaper())
            defer { harness.close() }
            let pdf = harness.pdf
            var linksInside: [(PDFAnnotation, PDFDestination)] = []
            var kinds: [String: Int] = [:]
            for index in 0..<pdf.pageCount {
                for annotation in pdf.page(at: index)?.annotations ?? [] where annotation.type == "Link" {
                    let target = try #require(ReaderKit.LinkClassifier.target(of: annotation))
                    let kind = String(target.kind.prefix { $0 != "(" })
                    kinds[kind, default: 0] += 1
                    if let destination = target.destination { linksInside.append((annotation, destination)) }
                }
            }
            SpikeLog.note("M3", "arXiv 2310.12457 link kinds: \(kinds)")
            #expect(linksInside.count > 100)
            #expect((kinds["web"] ?? 0) > 0)
            #expect(kinds["blocked"] == nil, "a paper's links are GoTo and URI only")
            for (_, destination) in linksInside {
                let page = try #require(destination.page)
                #expect(pdf.index(for: page) != NSNotFound)
            }

            // Preview a spread of them from where they sit, and follow one.
            harness.view.restore(try #require(harness.view.topAnchor(forPageAt: 0)))
            let place = try snapshot(harness.view)
            let sample = stride(from: 0, to: linksInside.count, by: max(1, linksInside.count / 12)).map { linksInside[$0] }
            for (annotation, destination) in sample {
                let request = LinkPreviewRequest(destination: destination, linkText: ReaderPDFView.text(of: annotation), sourceRect: .zero, trigger: .keyboard)
                harness.controller.showPreview(request, from: harness.primary)
                let preview = try #require(harness.previews.current)
                let shown = try #require(preview.previewView.visibleAnchor?.pageIndex)
                let wanted = pdf.index(for: try #require(destination.page))
                if preview.showsWholePage {
                    #expect(shown == wanted)
                } else {
                    // Scrolled to the target point, with the marker on it.
                    #expect(preview.previewView.targetMarker?.pageIndex == wanted)
                    let point = preview.previewView.convert(destination.point, from: try #require(destination.page))
                    #expect(preview.previewView.bounds.insetBy(dx: -2, dy: -2).contains(CGPoint(x: preview.previewView.bounds.midX, y: point.y)))
                }
                harness.controller.dismissPreview()
                expectUnmoved(place, in: harness.view)
            }
            #expect(harness.primary.history.isEmpty)

            // Clicking a citation or reference link on page 1 follows it.
            let firstPageLink = try #require(linksInside.first { $0.0.page === pdf.page(at: 0) && harness.view.bounds.contains(harness.center(of: $0.0)) })
            harness.click(firstPageLink.0)
            #expect(harness.primary.history.backList.count == 1)
            #expect(harness.view.visibleAnchor?.pageIndex == pdf.index(for: try #require(firstPageLink.1.page)))
            // Keyboard link focus finds that page's links with useful names.
            harness.controller.navigateBack(nil)
            let linkTop = firstPageLink.0.bounds.maxY + 20
            harness.view.restore(ReadingAnchor(pageIndex: 0, pointInPage: CGPoint(x: 0, y: linkTop), scale: 1))
            #expect(harness.view.beginLinkFocus())
            #expect(harness.view.focusableLinks.allSatisfy { $0.label.hasPrefix("Link to") })
            harness.view.endLinkFocus()
        }
    }
}

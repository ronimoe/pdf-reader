import AppKit
import PDFKit
import ReaderKit
import Testing

extension M0bSpikes {
    /// Q7: a second PDFView on the same PDFDocument (the preview popover),
    /// and how go(to:) treats unspecified and /Fit destinations.
    ///
    /// Offscreen captures don't include annotations (Q11), so "shows the
    /// annotation" is measured by the annotation effect layers PDFKit adds
    /// under a view's PDFPageView (`PDFPageLayer…AnnotationEffect`).
    @Suite struct Q7Preview {
        func annotationLayers(_ view: PDFView) -> Int {
            var count = 0
            func walk(_ layer: CALayer) {
                if String(describing: type(of: layer)).contains("AnnotationEffect") { count += 1 }
                layer.sublayers?.forEach(walk)
            }
            func find(_ v: NSView) {
                if String(describing: type(of: v)) == "PDFPageView", let layer = v.layer { walk(layer) }
                v.subviews.forEach(find)
            }
            find(view)
            return count
        }

        struct Pair {
            let first: ReaderPDFView
            let second: ReaderPDFView
            let host: OffscreenHost
            let document: PDFDocument
            var page: PDFPage { document.page(at: 0)! }
            var owner: AnyObject? { page.value(forKey: "view") as AnyObject? }
        }

        /// Main pane, then preview, both on one document, both showing page 0.
        func pair(annotateFirst: Bool = false, modes: (PDFDisplayMode, PDFDisplayMode) = (.singlePageContinuous, .singlePage)) throws -> Pair {
            let document = try #require(TestPDF.make(pageCount: 3).flatMap(PDFDocument.init(data:)))
            if annotateFirst { _ = addHighlight(to: document.page(at: 0)!) }
            let first = ReaderPDFView(frame: NSRect(x: 0, y: 0, width: 600, height: 900))
            let second = ReaderPDFView(frame: NSRect(x: 600, y: 300, width: 400, height: 600))
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 900))
            container.addSubview(first)
            container.addSubview(second)
            let host = OffscreenHost(content: container, size: container.frame.size)
            first.spikeLoad(document, mode: modes.0)
            second.spikeLoad(document, mode: modes.1)
            Spin.runLoop(0.3)
            return Pair(first: first, second: second, host: host, document: document)
        }

        @Test func twoViewsCanShareOneDocument() throws {
            let p = try pair()
            defer { p.host.close() }
            #expect(p.first.document === p.document)
            #expect(p.second.document === p.document)
            #expect(p.first.currentPage === p.second.currentPage)
            // The document delegate is a single slot shared by every view on it.
            #expect(p.document.delegate == nil)
        }

        @Test func existingAnnotationsShowInBothViews() throws {
            let p = try pair(annotateFirst: true)
            defer { p.host.close() }
            #expect(annotationLayers(p.first) == 1)
            #expect(annotationLayers(p.second) == 1)
        }

        /// PDFPage has a single private `view` slot: the view that last laid
        /// the page out. A live change reaches only that view.
        @Test(arguments: [
            (PDFDisplayMode.singlePageContinuous, PDFDisplayMode.singlePage),
            (PDFDisplayMode.singlePage, PDFDisplayMode.singlePageContinuous),
            (PDFDisplayMode.singlePage, PDFDisplayMode.singlePage),
        ])
        func liveAdditionReachesOnlyThePageOwner(modes: (PDFDisplayMode, PDFDisplayMode)) throws {
            let p = try pair(modes: modes)
            defer { p.host.close() }
            #expect(p.owner === p.second, "the last view to lay the page out owns it")
            _ = addHighlight(to: p.page)
            Spin.runLoop(0.5)
            #expect(annotationLayers(p.second) == 1)
            #expect(annotationLayers(p.first) == 0, "the other view does not show the new annotation")
            // annotationsChanged(on:) on the stale view does not help.
            p.first.annotationsChanged(on: p.page)
            Spin.runLoop(0.4)
            #expect(annotationLayers(p.first) == 0)
        }

        @Test func reassigningTheDocumentRefreshesTheStaleView() throws {
            let p = try pair()
            defer { p.host.close() }
            _ = addHighlight(to: p.page)
            Spin.runLoop(0.4)
            let document = p.first.document
            p.first.document = nil
            p.first.document = document
            Spin.runLoop(0.4)
            #expect(annotationLayers(p.first) == 1)
            #expect(p.owner === p.first, "ownership moves to the re-bound view")
            // Ownership flipped, so the next live change misses the *other* view.
            _ = addRedSquare(to: p.page)
            Spin.runLoop(0.4)
            SpikeLog.note("Q7", "after second live add: first=\(annotationLayers(p.first)) second=\(annotationLayers(p.second))")
            #expect(annotationLayers(p.first) == 2)
            #expect(annotationLayers(p.second) == 1)
        }

        @Test func removalReachesOnlyThePageOwnerToo() throws {
            let p = try pair(annotateFirst: true)
            defer { p.host.close() }
            let highlight = try #require(p.page.annotations.first)
            p.page.removeAnnotation(highlight)
            Spin.runLoop(0.4)
            SpikeLog.note("Q7", "after removal: first=\(annotationLayers(p.first)) second=\(annotationLayers(p.second))")
            #expect(annotationLayers(p.second) == 0)
            #expect(annotationLayers(p.first) == 1, "the stale view still shows the removed annotation")
        }

        struct Landing: CustomStringConvertible {
            var page: Int
            var visible: CGRect   // the preview's bounds, in page space
            var scale: CGFloat
            var current: CGPoint?
            var description: String {
                "page=\(page) visibleTop=\(Int(visible.maxY)) visibleLeft=\(Int(visible.minX)) visibleHeight=\(Int(visible.height)) scale=\(scale) currentDest=\(current.map { "(\(Int($0.x)), \(Int($0.y)))" } ?? "nil")"
            }
        }

        func land(_ destination: PDFDestination, in view: PDFView, document: PDFDocument) -> Landing {
            view.go(to: document.page(at: 0)!)
            Spin.runLoop(0.15)
            view.go(to: destination)
            Spin.runLoop(0.3)
            let page = view.currentPage!
            return Landing(
                page: document.index(for: page),
                visible: view.convert(view.bounds, to: page),
                scale: view.scaleFactor,
                current: view.currentDestination?.point
            )
        }

        @Test func goToDestinationVariants() throws {
            let document = try #require(PDFDocument(data: SpikeFixtures.links()))
            let view = PDFView(frame: .zero)
            let host = OffscreenHost(content: view, size: NSSize(width: 400, height: 300))
            defer { host.close() }
            view.spikeLoad(document, mode: .singlePageContinuous)
            let links = document.page(at: 0)!.annotations
            func destination(_ tag: String) throws -> PDFDestination {
                try #require((links.first { $0.contents == tag }?.action as? PDFActionGoTo)?.destination, "\(tag)")
            }
            let unspecified = kPDFDestinationUnspecifiedValue
            var landings: [String: Landing] = [:]
            let cases: [(String, PDFDestination)] = [
                ("xyz 0,792 (top of page 3)", try destination("goto-explicit")),
                ("xyz 100,500 zoom 2", try destination("goto-xyz-zoom")),
                ("xyz null null", try destination("goto-xyz-null")),
                ("fit", try destination("dest-fit")),
                ("fith 400", try destination("goto-fith")),
                ("fitr 72 72 300 300", try destination("goto-fitr")),
                ("constructed unspecified", PDFDestination(page: document.page(at: 2)!, at: CGPoint(x: unspecified, y: unspecified))),
                ("constructed y=300", PDFDestination(page: document.page(at: 2)!, at: CGPoint(x: 0, y: 300))),
            ]
            for (label, destination) in cases {
                let landing = land(destination, in: view, document: document)
                landings[label] = landing
                SpikeLog.note("Q7", "go(to:) \(label): dest point=\(destination.point) zoom=\(destination.zoom) → \(landing)")
            }
            // Every variant reaches the right page, and none changes the zoom
            // (/XYZ zoom 2 and /Fit are both ignored).
            #expect(landings.values.allSatisfy { $0.scale == 1 })
            #expect(landings["fit"]?.page == 1)
            for label in cases.map(\.0) where label != "fit" { #expect(landings[label]?.page == 2, "\(label)") }
            // An explicit top lands that y at the top of the view.
            #expect(abs((landings["xyz 0,792 (top of page 3)"]?.visible.maxY ?? 0) - 792) < 2)
            #expect(abs((landings["constructed y=300"]?.visible.maxY ?? 0) - 300) < 2)
            #expect(abs((landings["xyz 100,500 zoom 2"]?.visible.maxY ?? 0) - 500) < 2)
            // Unspecified top, /Fit, /FitH and /FitR: PDFKit exposes them all
            // as an unspecified point and shows the top of the page.
            for label in ["xyz null null", "fit", "fith 400", "fitr 72 72 300 300", "constructed unspecified"] {
                #expect(abs((landings[label]?.visible.maxY ?? 0) - 792) < 12, "\(label)")
            }
        }

        @Test func fitDestinationNeedsExplicitScaleForWholePage() throws {
            let document = try #require(PDFDocument(data: SpikeFixtures.links()))
            let view = PDFView(frame: .zero)
            let host = OffscreenHost(content: view, size: NSSize(width: 400, height: 300))
            defer { host.close() }
            view.spikeLoad(document, mode: .singlePage)
            // What the preview must do itself for /Fit (A3: whole page scaled to fit).
            view.go(to: document.page(at: 1)!)
            view.scaleFactor = view.scaleFactorForSizeToFit
            Spin.runLoop(0.2)
            let page = try #require(view.currentPage)
            let visible = view.convert(view.bounds, to: page)
            SpikeLog.note("Q7", "after scaleFactorForSizeToFit=\(view.scaleFactor): visible=\(visible)")
            #expect(view.scaleFactor < 0.4)
            #expect(visible.contains(page.bounds(for: .mediaBox).insetBy(dx: 1, dy: 1)))
        }
    }
}

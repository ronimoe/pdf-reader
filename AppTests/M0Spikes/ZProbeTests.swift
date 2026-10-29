import AppKit
import ObjectiveC
import PDFKit
import Testing

extension M0bSpikes {
    @Suite struct ZProbe {
        func census(_ view: PDFView) -> Int {
            var n = 0
            func walk(_ layer: CALayer) {
                if String(describing: type(of: layer)).contains("Annotation") { n += 1 }
                layer.sublayers?.forEach(walk)
            }
            func find(_ v: NSView) {
                if String(describing: type(of: v)) == "PDFPageView", let layer = v.layer { walk(layer) }
                v.subviews.forEach(find)
            }
            find(view)
            return n
        }

        @Test func probeRefreshStrategies() throws {
            let strategies: [(String, (PDFView, PDFPage) -> Void)] = [
                ("annotationsChanged", { v, p in v.annotationsChanged(on: p) }),
                ("layoutDocumentView", { v, _ in v.layoutDocumentView() }),
                ("needsDisplay all", { v, _ in v.needsDisplay = true; v.documentView?.subviews.forEach { $0.needsDisplay = true } }),
                ("go(to: page)", { v, p in v.go(to: p) }),
                ("toggle displayMode", { v, _ in let m = v.displayMode; v.displayMode = m == .singlePage ? .singlePageContinuous : .singlePage; v.displayMode = m }),
                ("page.setView(self)+annotationsChanged", { v, p in p.perform(NSSelectorFromString("setView:"), with: v); v.annotationsChanged(on: p) }),
                ("reassign document", { v, _ in let d = v.document; v.document = nil; v.document = d }),
            ]
            for (label, strategy) in strategies {
                let document = try #require(TestPDF.make(pageCount: 3).flatMap(PDFDocument.init(data:)))
                let page = try #require(document.page(at: 0))
                let first = PDFView(frame: NSRect(x: 0, y: 0, width: 500, height: 900))
                let second = PDFView(frame: NSRect(x: 500, y: 0, width: 500, height: 900))
                let container = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 900))
                container.addSubview(first)
                container.addSubview(second)
                let host = OffscreenHost(content: container, size: container.frame.size)
                defer { host.close() }
                first.spikeLoad(document, mode: .singlePage)
                second.spikeLoad(document, mode: .singlePage)
                let owner = page.value(forKey: "view") as AnyObject?
                _ = addHighlight(to: page)
                Spin.runLoop(0.4)
                let before = (census(first), census(second))
                strategy(first, page)
                Spin.runLoop(0.5)
                SpikeLog.note("probe", "\(label): page.view is second=\(owner === second) first=\(owner === first); before=\(before) after first/second=(\(census(first)), \(census(second))) ownerNow first=\((page.value(forKey: "view") as AnyObject?) === first)")
            }
        }
    }
}

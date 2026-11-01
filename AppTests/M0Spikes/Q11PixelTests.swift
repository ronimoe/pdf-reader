import AppKit
import PDFKit
import Testing

/// Adds a red, filled square annotation in an empty area of a TestPDF page.
func addRedSquare(to page: PDFPage) -> PDFAnnotation {
    let annotation = PDFAnnotation(bounds: CGRect(x: 300, y: 300, width: 100, height: 100), forType: .square, withProperties: nil)
    annotation.color = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    annotation.interiorColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    page.addAnnotation(annotation)
    return annotation
}

extension M0bSpikes {
    /// Q11: which offscreen rendering paths produce real pixels.
    @Suite struct Q11Pixels {
        static var onVirtualMachine: Bool {
            var value: Int32 = 0
            var size = MemoryLayout<Int32>.size
            return sysctlbyname("kern.hv_vmm_present", &value, &size, nil, 0) == 0 && value == 1
        }

        @Test func pageDrawIntoCGContextRendersTextAndAnnotations() throws {
            let document = try #require(TestPDF.make(pageCount: 1).flatMap(PDFDocument.init(data:)))
            let page = try #require(document.page(at: 0))
            let plain = PixelStats.of(PixelStats.render(page))
            _ = addHighlight(to: page)
            _ = addRedSquare(to: page)
            let annotated = PixelStats.of(PixelStats.render(page))
            SpikeLog.note("Q11", "PDFPage.draw(with:to:) plain: \(plain); annotated: \(annotated)")
            #expect(plain.dark > 200, "text pixels present")
            #expect(plain.yellow == 0 && plain.red == 0)
            #expect(annotated.yellow > 5_000, "highlight drawn")
            #expect(annotated.red > 5_000, "square drawn")
        }

        /// Captures a PDFView offscreen three ways. Text is 1×-rendered as
        /// about 370 dark pixels, so about 1,500 at the 2× backing scale.
        @Test func pdfViewOffscreenCapture() throws {
            let document = try #require(TestPDF.make(pageCount: 1).flatMap(PDFDocument.init(data:)))
            let page = try #require(document.page(at: 0))
            _ = addHighlight(to: page)
            _ = addRedSquare(to: page)
            let view = PDFView(frame: .zero)
            let host = OffscreenHost(content: view, size: NSSize(width: 640, height: 820))
            defer { host.close() }
            view.spikeLoad(document, mode: .singlePage)
            view.display()
            Spin.runLoop(1.0)

            let cache = try #require(view.cachedDisplayImage().map(PixelStats.of))
            let docCache = try #require(view.documentView?.cachedDisplayImage().map(PixelStats.of))
            let layer = try #require(view.layerRenderedImage().map(PixelStats.of))
            SpikeLog.note("Q11", "PDFView.cacheDisplay: \(cache)")
            SpikeLog.note("Q11", "documentView.cacheDisplay: \(docCache)")
            SpikeLog.note("Q11", "layer.render(in:): \(layer)")
            SpikeLog.note("Q11", "backingScale=\(host.window.backingScaleFactor)")
            for (name, stats) in [("cacheDisplay", cache), ("documentView.cacheDisplay", docCache), ("layer.render", layer)] {
                if Self.onVirtualMachine {
                    // CI's macOS runners are virtual machines, with a 1× display: there these
                    // captures are entirely blank, on macOS 26 and 27 alike.
                    #expect(stats.nonWhite == 0, "\(name): blank on a virtual machine")
                } else {
                    // Not blank: page text is captured…
                    #expect(stats.dark > 800, "\(name): page text captured")
                }
                // …but neither annotation is: they're drawn outside what these paths capture.
                #expect(stats.yellow == 0, "\(name): highlight not captured")
                #expect(stats.red == 0, "\(name): square not captured")
            }
        }
    }
}

import AppKit
import ObjectiveC
import PDFKit
import Testing

/// A page whose reported rotation adds a view-only offset, without
/// changing what is stored in the PDF page dictionary.
nonisolated final class ViewRotatedPage: PDFPage {
    nonisolated(unsafe) static var extraRotation = 0
    override var rotation: Int {
        get { (super.rotation + Self.extraRotation) % 360 }
        set { super.rotation = newValue }
    }
}

nonisolated final class ViewRotatedDocument: PDFDocument {
    override var pageClass: AnyClass { ViewRotatedPage.self }
}

extension M0bSpikes {
    /// Q4: is PDFPage.rotation serialised, and is there a view-only rotation?
    @Suite struct Q4Rotation {
        func rotateDict(_ data: Data) -> [String] {
            PDFBytes.objects(containing: "/Type /Page ", in: data).compactMap { body in
                body.range(of: "/Rotate [0-9]+", options: .regularExpression).map { String(body[$0]) }
            }
        }

        @Test func rotationIsWrittenByDataRepresentationAndWrite() throws {
            let original = try #require(TestPDF.make(pageCount: 2))
            let document = try #require(PDFDocument(data: original))
            let page = try #require(document.page(at: 0))
            page.rotation = 90

            let data = try #require(document.dataRepresentation())
            #expect(rotateDict(data).sorted() == ["/Rotate 0", "/Rotate 90"])
            #expect(PDFDocument(data: data)?.page(at: 0)?.rotation == 90)

            let url = SpikeArtifacts.directory.appendingPathComponent("q4-rotated.pdf")
            #expect(document.write(to: url))
            let written = try Data(contentsOf: url)
            #expect(rotateDict(written).sorted() == ["/Rotate 0", "/Rotate 90"])
            #expect(PDFDocument(url: url)?.page(at: 0)?.rotation == 90)

            // Restoring the recorded original value takes it back out.
            page.rotation = 0
            let restored = try #require(document.dataRepresentation())
            #expect(rotateDict(restored) == ["/Rotate 0", "/Rotate 0"])
        }

        @Test func pdfViewHasNoRotationAPI() {
            // Selectors on PDFView itself mentioning rotation (public or private).
            var count: UInt32 = 0
            let list = class_copyMethodList(PDFView.self, &count)
            defer { free(list) }
            let rotationSelectors = (0..<Int(count)).map { NSStringFromSelector(method_getName(list![$0])) }
                .filter { $0.lowercased().contains("rotat") }
            SpikeLog.note("Q4", "PDFView selectors mentioning rotation: \(rotationSelectors)")
            #expect(!PDFView.instancesRespond(to: NSSelectorFromString("setRotation:")))
            #expect(!PDFView.instancesRespond(to: NSSelectorFromString("setPageRotation:")))
        }

        /// The candidate for a view-only rotation: a PDFPage subclass that
        /// reports an extra rotation. Does the view rotate, and does the
        /// extra rotation leak into the written file?
        @Test func pageSubclassRotationOverride() throws {
            let original = try #require(TestPDF.make(pageCount: 1))
            ViewRotatedPage.extraRotation = 0
            let document = try #require(ViewRotatedDocument(data: original))
            let page = try #require(document.page(at: 0))
            #expect(page is ViewRotatedPage)

            let view = PDFView(frame: .zero)
            let host = OffscreenHost(content: view)
            defer { host.close() }
            view.spikeLoad(document, mode: .singlePage)
            let uprightSize = view.documentView?.frame.size ?? .zero

            ViewRotatedPage.extraRotation = 90
            view.layoutDocumentView()
            Spin.runLoop(0.2)
            let rotatedSize = view.documentView?.frame.size ?? .zero
            let boundsInView = view.convert(page.bounds(for: .mediaBox), from: page)
            let drawn = PixelStats.render(page)
            let data = try #require(document.dataRepresentation())
            ViewRotatedPage.extraRotation = 0

            SpikeLog.note("Q4", "subclass override: documentView upright=\(uprightSize) rotated=\(rotatedSize) pageRectInView=\(boundsInView) drawn=\(drawn.width)x\(drawn.height) written=\(rotateDict(data))")
            // The view lays the page out rotated (landscape)…
            #expect(rotatedSize.width > rotatedSize.height)
            #expect(uprightSize.height > uprightSize.width)
            // …and the writer also asks the page, so the override leaks into the file.
            #expect(rotateDict(data) == ["/Rotate 90"])
        }
    }
}

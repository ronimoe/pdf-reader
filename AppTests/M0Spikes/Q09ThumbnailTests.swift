import AppKit
import PDFKit
import Testing

/// The architecture's thumbnail actor (§4.6): it opens its own PDFDocument
/// from the same bytes and never shares PDFKit objects with the main thread.
actor ThumbnailRenderer {
    struct Result: Sendable {
        var count = 0
        var seconds = 0.0
        var sampledNonBlank = 0
        var sampled = 0
        var ranOnMainThread = false
    }

    private let document: PDFDocument

    init(data: Data) throws {
        guard let document = PDFDocument(data: data) else { throw CocoaError(.fileReadCorruptFile) }
        self.document = document
    }

    var pageCount: Int { document.pageCount }

    func thumbnailStats(page index: Int, size: CGSize) -> PixelStats? {
        document.page(at: index)?.thumbnail(of: size, for: .mediaBox).cgImageValue.map(PixelStats.of)
    }

    func render(pages: Range<Int>, size: CGSize, sampleEvery: Int = 50) -> Result {
        var result = Result()
        result.ranOnMainThread = Thread.isMainThread
        let start = monotonicSeconds()
        for index in pages {
            guard let page = document.page(at: index) else { continue }
            // Rasterise every thumbnail: NSImage may defer drawing until asked.
            guard let cg = page.thumbnail(of: size, for: .mediaBox).cgImageValue else { continue }
            result.count += 1
            if index % sampleEvery == 0 {
                result.sampled += 1
                if PixelStats.of(cg).nonWhite > 100 { result.sampledNonBlank += 1 }
            }
        }
        result.seconds = monotonicSeconds() - start
        return result
    }
}

extension M0bSpikes {
    /// Q9: thumbnails on a background actor with a second PDFDocument.
    @Suite struct Q9Thumbnails {
        static let size = CGSize(width: 120, height: 160)

        @Test func backgroundActorRendersWhileMainThreadUsesItsOwnDocument() async throws {
            let data = BigPDF.pages600
            let mainDocument = try #require(PDFDocument(data: data))
            let renderer = try ThumbnailRenderer(data: data)
            #expect(await renderer.pageCount == 600)

            let start = monotonicSeconds()
            async let background = renderer.render(pages: 0..<600, size: Self.size)
            // Meanwhile the main thread keeps rendering pages of its own document.
            var mainRendered = 0
            for index in stride(from: 0, to: 600, by: 5) {
                let stats = PixelStats.of(PixelStats.render(mainDocument.page(at: index)!, scale: 0.25))
                if stats.dark > 0 { mainRendered += 1 }
                await Task.yield()
            }
            let mainSeconds = monotonicSeconds() - start
            let result = await background
            let wall = monotonicSeconds() - start
            SpikeLog.note("Q9", String(format: "600 thumbnails %.0fx%.0f on actor: %.2f s (%.1f ms/page), wall %.2f s; main thread drew %d pages concurrently in %.2f s; sampled non-blank %d/%d; ranOnMain=%@",
                                       Self.size.width, Self.size.height, result.seconds, result.seconds * 1000 / 600, wall, mainRendered, mainSeconds, result.sampledNonBlank, result.sampled, "\(result.ranOnMainThread)"))
            #expect(result.count == 600)
            #expect(result.ranOnMainThread == false)
            #expect(result.sampledNonBlank == result.sampled)
            #expect(mainRendered == 120)
            #expect(result.seconds < 30, "loose bound; see the spike doc for measured numbers")
        }

        @Test func backgroundAndMainThumbnailsMatch() async throws {
            let data = BigPDF.pages600
            let renderer = try ThumbnailRenderer(data: data)
            let mainDocument = try #require(PDFDocument(data: data))
            for index in [0, 299, 599] {
                let background = await renderer.thumbnailStats(page: index, size: Self.size)
                let main = mainDocument.page(at: index)?.thumbnail(of: Self.size, for: .mediaBox).cgImageValue.map(PixelStats.of)
                SpikeLog.note("Q9", "page \(index) thumbnail: background \(String(describing: background)) main \(String(describing: main))")
                #expect(background?.nonWhite == main?.nonWhite)
                #expect((background?.nonWhite ?? 0) > 100)
            }
        }

        @Test func twoActorsInParallel() async throws {
            let data = BigPDF.pages600
            let a = try ThumbnailRenderer(data: data)
            let b = try ThumbnailRenderer(data: data)
            let start = monotonicSeconds()
            async let first = a.render(pages: 0..<300, size: Self.size)
            async let second = b.render(pages: 300..<600, size: Self.size)
            let (r1, r2) = await (first, second)
            let wall = monotonicSeconds() - start
            SpikeLog.note("Q9", String(format: "two actors x 300 pages: wall %.2f s (actor times %.2f s, %.2f s)", wall, r1.seconds, r2.seconds))
            #expect(r1.count + r2.count == 600)
        }
    }
}

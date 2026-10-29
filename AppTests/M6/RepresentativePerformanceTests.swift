import AppKit
import Darwin
import PDFKit
import Persistence
import ReaderCore
import ReaderKit
import Testing
@testable import Lectern

/// Performance on the representative documents (spec §9.1, architecture §9, A6). The numbers,
/// the machine and the thresholds are in docs/performance.md.
///
/// These are slow, so `scripts/test.sh` doesn't run them: `scripts/perf.sh` copies the files into
/// the test host's sandbox container (it can't read the repository) and drops the `enabled` marker
/// there, then runs only this suite. Every measurement is written as one `PERF|…` line to
/// `results.txt` beside the files, which perf.sh copies out and counts, and a measurement over
/// its threshold fails its test.
///
/// Measured in the Debug build `xcodebuild test` makes. Almost all the time is PDFKit's and
/// CoreGraphics' own (optimised system code); the app's share is small, so Release would differ
/// little. The windows are never ordered on screen: PDFKit draws nothing offscreen (M0b Q11), so
/// "drawing" means `PDFPage.draw(with:to:)` into a bitmap at the pane's scale on a Retina display,
/// the work PDFKit's tiles do for a page coming into view.
nonisolated enum PerfCorpus {
    static let folder = FileManager.default.temporaryDirectory.appending(path: "LecternPerfCorpus", directoryHint: .isDirectory)
    static var isEnabled: Bool { FileManager.default.fileExists(atPath: folder.appending(path: "enabled").path) }

    static let book = "gpo-style-manual-2016.pdf"            // 475 pages, text-heavy
    static let manual = "postgresql-17.11-US.pdf"            // 3,270 pages, 18,553 links
    static let images = "nasa-earth-at-night.pdf"            // 200 pages, full-page imagery
    static let scan = "annals-surgery-1886-anthrax-scan.pdf" // 46 scanned pages, no text layer
    static let all = [book, manual, images, scan]

    static func url(_ name: String) throws -> URL {
        let url = folder.appending(path: name)
        try #require(FileManager.default.fileExists(atPath: url.path), "\(name) isn't staged; run scripts/perf.sh")
        return url
    }
}

/// The thresholds (docs/performance.md explains each). Provisional: set on an M3 Pro with about 2×
/// headroom over what it measured (more where a single frame or an interaction is the natural
/// bound), to be checked on the A6 baseline, a base M1 with 8 GB, before they count as release
/// criteria. The M3 Pro figures in the comments are the worst over the last runs recorded in
/// docs/performance.md; keep the two in step.
nonisolated enum PerfLimit {
    static let openToFirstPage = 1.0           // s, open a document and draw page 1 (M3 Pro: ≤ 0.44, the manual)
    static let scrollStepMainThread = 0.016    // s, p95 main-thread cost of one page of scrolling: one 60 Hz frame
    static let pageDraw95 = 0.25               // s, p95 time to draw a page coming into view (M3 Pro: ≤ 0.10, images)
    static let searchFirstResult = 1.0         // s, until the first result reaches the list (M3 Pro: ≤ 0.46)
    static let searchMainThreadGap = 0.10      // s, longest the main thread is busy during a search (M3 Pro: ≤ 0.057)
    static let thumbnailsPerSecond = 20.0      // pages/s, sidebar thumbnails on the background actor (M3 Pro: ≥ 41)
    static let annotationList = 0.05           // s, building the annotation list of the 3,270-page manual (M3 Pro: ≤ 0.003)
    static let saveOneHighlight = 1.5          // s, ⌘S of one highlight on the 3,270-page manual (M3 Pro: 0.73–0.75)
    static let scrollMemoryGrowth = 1_000.0    // MB, footprint growth while scrolling a whole document (M3 Pro: ≤ 635, the manual)

    /// A whole-document search, by file (M3 Pro: book ≤ 3.0 s, manual ≤ 9.9 s).
    static func searchComplete(_ file: String) -> Double { file == PerfCorpus.manual ? 20 : 6 }

    /// Footprint growth once every page has been drawn: PDFKit keeps each drawn page's cache while
    /// the document is open (M3 Pro: book 265–398 MB, manual 3,060–3,170 MB, images 64–94 MB,
    /// scan 74–90 MB). These guard against regressions on this machine only: none of them says
    /// whether an 8 GB Mac copes, and the baseline run has to set real limits.
    static func drawnPagesMemoryGrowth(_ file: String) -> Double {
        switch file {
        case PerfCorpus.manual: 8_000
        case PerfCorpus.images: 1_200
        case PerfCorpus.book: 800
        default: 200
        }
    }
}

nonisolated enum PerfReport {
    static func record(_ name: String, _ value: Double, unit: String, limit: Double, lowerIsBetter: Bool = true) {
        let line = String(format: "PERF|%@|%.4f|%@|%.4f|%@", name, value, unit, limit, lowerIsBetter ? "max" : "min")
        NSLog("%@", line)
        let results = PerfCorpus.folder.appending(path: "results.txt")
        if let handle = try? FileHandle(forWritingTo: results) {
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
            try? handle.close()
        } else {
            try? Data((line + "\n").utf8).write(to: results)
        }
        let within = lowerIsBetter ? value <= limit : value >= limit
        #expect(within, "\(name): \(value) \(unit), threshold \(lowerIsBetter ? "≤" : "≥") \(limit)")
    }

    static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    /// The process's physical footprint (what Activity Monitor calls Memory), in MB.
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }

    /// Draws `page` the way a pane at `scale` on a 2× display needs it, into a bitmap.
    @discardableResult
    static func draw(_ page: PDFPage, scale: CGFloat) -> Bool {
        let box = page.bounds(for: .cropBox)
        let pixels = scale * 2
        let width = max(1, Int(box.width * pixels)), height = max(1, Int(box.height * pixels))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: pixels, y: pixels)
        page.draw(with: .cropBox, to: context)
        return true
    }
}

@MainActor
@Suite(.serialized, .noUI, .enabled(if: PerfCorpus.isEnabled, "run by scripts/perf.sh"), .timeLimit(.minutes(30)))
struct RepresentativePerformanceTests {
    /// A reader window the size of a 14-inch laptop's, never ordered on screen.
    private func open(_ url: URL, folder: TemporaryFolder) throws -> NavigationHarness {
        try NavigationHarness(file: url, store: folder.store(), size: NSSize(width: 900, height: 1000))
    }

    // MARK: Opening

    /// Open (read, parse, the window, the panes) until page 1 has been drawn. Median of three.
    @Test(arguments: PerfCorpus.all) func openToFirstPageDrawn(_ name: String) throws {
        let url = try PerfCorpus.url(name)
        var times: [Double] = []
        for _ in 0..<3 {
            let folder = try TemporaryFolder()
            let start = PerfReport.now()
            let harness = try open(url, folder: folder)
            let view = harness.pdfView
            let page = try #require(view.document?.page(at: 0))
            #expect(PerfReport.draw(page, scale: view.scaleFactor))
            times.append(PerfReport.now() - start)
            #expect(harness.controller.isShowingContent)
            harness.close()
        }
        PerfReport.record("open-to-first-page/\(name)", PerfReport.percentile(times, 0.5), unit: "s", limit: PerfLimit.openToFirstPage)
    }

    // MARK: Scrolling and memory

    /// Continuous scrolling through the whole document, one page height per step, as a scroll wheel
    /// moves it: the main thread's scroll and layout per step, and the footprint, sampled after
    /// every step. Offscreen, PDFKit draws nothing, so this is the view's own cost; drawing is
    /// measured next.
    @Test(arguments: [PerfCorpus.book, PerfCorpus.manual, PerfCorpus.images, PerfCorpus.scan])
    func scrollingThroughTheDocument(_ name: String) throws {
        let folder = try TemporaryFolder()
        let baseline = PerfReport.footprintMB()
        let harness = try open(try PerfCorpus.url(name), folder: folder)
        defer { harness.close() }
        let view = harness.pdfView
        let document = try #require(view.document)
        var steps: [Double] = [], peak = baseline
        for step in 1..<document.pageCount {
            let height = (document.page(at: step - 1)?.bounds(for: .cropBox).height ?? 792) * view.scaleFactor
            autoreleasepool {
                let start = PerfReport.now()
                harness.userScroll(by: height)
                view.layoutSubtreeIfNeeded()
                steps.append(PerfReport.now() - start)
            }
            peak = max(peak, PerfReport.footprintMB())
            if step % 25 == 0 { Spin.runLoop(0.001) }
        }
        #expect((harness.currentPageIndex ?? 0) >= document.pageCount - 3, "scrolling reached page \((harness.currentPageIndex ?? 0) + 1) of \(document.pageCount)")
        NSLog("scroll %@: %d steps, step p50 %.2f ms, p95 %.2f ms, max %.2f ms; footprint %.0f → peak %.0f MB",
              name, steps.count, PerfReport.percentile(steps, 0.5) * 1000, PerfReport.percentile(steps, 0.95) * 1000,
              (steps.max() ?? 0) * 1000, baseline, peak)
        PerfReport.record("scroll-step-main-thread-p95/\(name)", PerfReport.percentile(steps, 0.95), unit: "s", limit: PerfLimit.scrollStepMainThread)
        PerfReport.record("scroll-memory-growth/\(name)", peak - baseline, unit: "MB", limit: PerfLimit.scrollMemoryGrowth)
    }

    /// Every page drawn once, in order, as scrolling brings it into view: the time per page at
    /// the pane's scale on a 2× display, and the footprint once all have been drawn.
    @Test(arguments: [PerfCorpus.book, PerfCorpus.manual, PerfCorpus.images, PerfCorpus.scan])
    func drawingEveryPage(_ name: String) throws {
        let folder = try TemporaryFolder()
        let baseline = PerfReport.footprintMB()
        let harness = try open(try PerfCorpus.url(name), folder: folder)
        defer { harness.close() }
        let view = harness.pdfView
        let document = try #require(view.document)
        let scale = view.scaleFactor
        var draws: [Double] = [], peak = baseline
        for index in 0..<document.pageCount {
            let page = try #require(document.page(at: index))
            // The bitmap is this test's, not the app's: let it go before sampling the footprint.
            autoreleasepool {
                let start = PerfReport.now()
                PerfReport.draw(page, scale: scale)
                draws.append(PerfReport.now() - start)
            }
            peak = max(peak, PerfReport.footprintMB())
        }
        NSLog("draw %@: %d pages at scale %.2f, p50 %.1f ms, p95 %.1f ms, max %.1f ms; footprint %.0f → peak %.0f MB",
              name, draws.count, scale, PerfReport.percentile(draws, 0.5) * 1000, PerfReport.percentile(draws, 0.95) * 1000,
              (draws.max() ?? 0) * 1000, baseline, peak)
        PerfReport.record("page-draw-p95/\(name)", PerfReport.percentile(draws, 0.95), unit: "s", limit: PerfLimit.pageDraw95)
        PerfReport.record("drawn-pages-memory-growth/\(name)", peak - baseline, unit: "MB", limit: PerfLimit.drawnPagesMemoryGrowth(name))
    }

    // MARK: Search

    struct SearchCase: Sendable, CustomTestStringConvertible {
        let file: String
        let query: String
        var wholeWord = false
        /// One match, near the end: its first result is its completion, so only that is timed.
        var rare = false
        var testDescription: String { "\(query) in \(file)\(wholeWord ? " (whole word)" : "")" }
    }

    /// A common word (thousands of matches; past the 5,000-row cap on the manual, and Whole Word
    /// filtering on the book) and a rare word whose only match is in the last pages.
    @Test(arguments: [
        SearchCase(file: PerfCorpus.book, query: "the", wholeWord: true),
        SearchCase(file: PerfCorpus.book, query: "steamships", rare: true),
        SearchCase(file: PerfCorpus.manual, query: "table"),
        SearchCase(file: PerfCorpus.manual, query: "retryable", rare: true),
    ])
    func search(_ c: SearchCase) throws {
        let folder = try TemporaryFolder()
        let harness = try open(try PerfCorpus.url(c.file), folder: folder)
        defer { harness.close() }
        if c.wholeWord { harness.controller.toggleWholeWord(nil) }

        let meter = MainThreadMeter()
        let start = PerfReport.now()
        harness.controller.startSearch(c.query)
        let search = try #require(harness.controller.search)
        // When the results list first shows a result: the controller's own update, wrapped.
        let update = search.onChange
        search.onChange = {
            if meter.firstShown == nil, !search.results.isEmpty { meter.firstShown = PerfReport.now() - start }
            update?()
        }
        meter.start()
        defer { meter.stop() }
        var firstFound: Double?
        while search.isSearching, PerfReport.now() - start < 120 {
            Spin.runLoop(0.001)
            if firstFound == nil, !search.results.isEmpty { firstFound = PerfReport.now() - start }
        }
        let total = PerfReport.now() - start
        #expect(!search.isSearching)
        #expect(!search.results.isEmpty, "no match for \(c.query)")
        NSLog("search %@: %d results, first found %.3f s, first shown %.3f s, done %.3f s, longest main-thread gap %.1f ms",
              c.testDescription, search.results.count, firstFound ?? -1, meter.firstShown ?? -1, total, meter.longestGap * 1000)
        let label = "\(c.query)/\(c.file)"
        if !c.rare {
            PerfReport.record("search-first-result/\(label)", meter.firstShown ?? .infinity, unit: "s", limit: PerfLimit.searchFirstResult)
        }
        PerfReport.record("search-complete/\(label)", total, unit: "s", limit: PerfLimit.searchComplete(c.file))
        PerfReport.record("search-main-thread-gap/\(label)", meter.longestGap, unit: "s", limit: PerfLimit.searchMainThreadGap)
    }

    // MARK: Thumbnails

    /// The sidebar's renderer (its own document, on its actor), 150 pages or the whole file.
    @Test(arguments: [PerfCorpus.book, PerfCorpus.manual, PerfCorpus.images, PerfCorpus.scan])
    func thumbnailThroughput(_ name: String) async throws {
        let data = try Data(contentsOf: try PerfCorpus.url(name))
        let renderer = PageRenderer(data: data)
        let count = min(150, await renderer.pageCount)
        let start = PerfReport.now()
        for index in 0..<count {
            let image = await renderer.thumbnail(pageIndex: index, fitting: CGSize(width: 120, height: 160), scale: 2, rotation: 0)
            #expect(image != nil)
        }
        let rate = Double(count) / (PerfReport.now() - start)
        PerfReport.record("thumbnails-per-second/\(name)", rate, unit: "pages/s", limit: PerfLimit.thumbnailsPerSecond, lowerIsBetter: false)
    }

    // MARK: Annotations

    /// The annotation list of the 3,270-page manual (18,553 links, nothing listed), before and after
    /// a highlight deep in it, and ⌘S of that highlight.
    @Test func annotationListAndSavingOnTheLongManual() async throws {
        let source = try PerfCorpus.url(PerfCorpus.manual)
        let folder = try TemporaryFolder()
        let file = folder.url.appending(path: PerfCorpus.manual)
        try FileManager.default.copyItem(at: source, to: file)
        let inspectionStart = PerfReport.now()
        let harness = try await AnnotationHarness(file: file, folder: folder)
        defer { harness.close() }
        NSLog("annotation inspection of the manual (background): %.3f s after open", PerfReport.now() - inspectionStart)
        let controller = harness.controller

        func timeList() -> (seconds: Double, count: Int) {
            controller.annotationListCache = nil
            let start = PerfReport.now()
            let count = controller.annotationList.count
            return (PerfReport.now() - start, count)
        }
        let empty = timeList()
        #expect(empty.count == 0)
        PerfReport.record("annotation-list/empty/\(PerfCorpus.manual)", empty.seconds, unit: "s", limit: PerfLimit.annotationList)

        // What reading every page cost (the list before M6), for docs/performance.md.
        let scanStart = PerfReport.now()
        var links = 0
        for index in 0..<harness.pdf.pageCount { links += harness.pdf.page(at: index)?.annotations.count ?? 0 }
        NSLog("reading every page's annotations (the list before M6): %.3f s, %d annotations", PerfReport.now() - scanStart, links)

        // One highlight on page 2,001.
        let page = try #require(harness.pdf.page(at: 2000))
        let line = try #require(page.selection(for: page.bounds(for: .cropBox))?.selectionsByLine().first { ($0.string ?? "").count > 10 })
        let added = try harness.editor.addMarkup(.highlight, covering: line, color: .yellow)
        #expect(added.count == 1)
        let one = timeList()
        #expect(one.count == 1)
        PerfReport.record("annotation-list/one-highlight/\(PerfCorpus.manual)", one.seconds, unit: "s", limit: PerfLimit.annotationList)

        let saveStart = PerfReport.now()
        try await harness.save()
        let saved = PerfReport.now() - saveStart
        #expect(!harness.document.isDocumentEdited)
        #expect(harness.fileBytes.count > (try Data(contentsOf: source)).count)
        PerfReport.record("save-one-highlight/\(PerfCorpus.manual)", saved, unit: "s", limit: PerfLimit.saveOneHighlight)
        #expect(timeList().count == 1, "the saved highlight is still listed")
    }
}

/// The longest the main thread goes without turning its run loop, sampled by a 2 ms timer in the
/// common modes; and when a search's first result was shown.
@MainActor
final class MainThreadMeter {
    var firstShown: Double?
    private(set) var longestGap = 0.0
    private var lastTick = 0.0
    private var timer: Timer?

    func start() {
        lastTick = PerfReport.now()
        let timer = Timer(timeInterval: 0.002, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() { timer?.invalidate() }

    private func tick() {
        let now = PerfReport.now()
        longestGap = max(longestGap, now - lastTick)
        lastTick = now
    }
}

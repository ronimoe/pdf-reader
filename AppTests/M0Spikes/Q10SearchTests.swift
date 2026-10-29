import AppKit
import CoreText
import PDFKit
import Testing

/// Records find callbacks from whatever thread they arrive on.
nonisolated final class FindRecorder: NSObject, PDFDocumentDelegate, @unchecked Sendable {
    struct Event: Sendable {
        let name: String
        let time: Double
        let onMain: Bool
    }

    let events = Locked<[Event]>([])
    private var tokens: [NSObjectProtocol] = []

    func record(_ name: String) {
        events.withLock { $0.append(Event(name: name, time: monotonicSeconds(), onMain: Thread.isMainThread)) }
    }

    func observe(_ document: PDFDocument) {
        let center = NotificationCenter.default
        let names: [(Notification.Name, String)] = [
            (.PDFDocumentDidBeginFind, "begin"),
            (.PDFDocumentDidFindMatch, "match"),
            (.PDFDocumentDidEndPageFind, "endPage"),
            (.PDFDocumentDidEndFind, "end"),
        ]
        for (name, label) in names {
            tokens.append(center.addObserver(forName: name, object: document, queue: nil) { [weak self] _ in self?.record(label) })
        }
    }

    func stop() { tokens.forEach(NotificationCenter.default.removeObserver) }

    // PDFDocumentDelegate
    func didMatchString(_ instance: PDFSelection) { record("delegateMatch") }
}

extension M0bSpikes {
    /// Q10: does beginFindString report progressively, on which thread, and
    /// does the main thread stay responsive on a 2,400-page document?
    @Suite struct Q10Search {
        /// With `viaDelegate`, the document delegate implements
        /// didMatchString:; otherwise results come only as notifications.
        @Test(arguments: [false, true])
        func asynchronousFindOn2400Pages(viaDelegate: Bool) async throws {
            let data = BigPDF.pages2400
            let document = try #require(PDFDocument(data: data))
            #expect(document.pageCount == 2400)
            let expectedMatches = BigPDF.needlePages(pageCount: 2400, every: 50).count

            let recorder = FindRecorder()
            recorder.observe(document)
            if viaDelegate { document.delegate = recorder }
            defer { recorder.stop(); document.delegate = nil }

            // A 5 ms main-run-loop timer; gaps between ticks measure how long
            // the main thread was unavailable.
            let ticks = Locked<[Double]>([])
            let timer = Timer(timeInterval: 0.005, repeats: true) { _ in ticks.withLock { $0.append(monotonicSeconds()) } }
            RunLoop.main.add(timer, forMode: .common)
            defer { timer.invalidate() }
            try await Task.sleep(for: .milliseconds(50))

            let start = monotonicSeconds()
            document.beginFindString(BigPDF.needle, withOptions: .caseInsensitive)
            let returned = monotonicSeconds() - start
            let findingRightAfter = document.isFinding
            while !recorder.events.current.contains(where: { $0.name == "end" }) && monotonicSeconds() - start < 120 {
                try await Task.sleep(for: .milliseconds(10))
            }
            let events = recorder.events.current
            let counts = Dictionary(grouping: events, by: \.name).mapValues(\.count)
            SpikeLog.note("Q10", "viaDelegate=\(viaDelegate) event counts: \(counts)")
            let matchName = viaDelegate ? "delegateMatch" : "match"
            let matches = events.filter { $0.name == matchName }
            let firstMatch = (matches.first?.time ?? .infinity) - start
            let end = (events.first { $0.name == "end" }?.time ?? .infinity) - start
            let window = ticks.current.filter { $0 >= start && $0 <= start + end }
            let maxGap = zip(window, window.dropFirst()).map { $1 - $0 }.max() ?? 0
            let matchesBeforeHalf = matches.filter { $0.time - start < end / 2 }.count
            let threads = Dictionary(grouping: events, by: \.name).mapValues { group in Set(group.map(\.onMain)) }

            SpikeLog.note("Q10", String(format: "viaDelegate=%@: beginFindString returned in %.1f ms (isFinding=%@); first match %.3f s; end %.3f s; matches %d; endPage %d; timer ticks %d; max main-thread gap %.1f ms; matches in first half %d",
                                        "\(viaDelegate)", returned * 1000, "\(findingRightAfter)", firstMatch, end, matches.count, counts["endPage"] ?? 0, window.count, maxGap * 1000, matchesBeforeHalf))
            SpikeLog.note("Q10", "viaDelegate=\(viaDelegate) callback threads (onMain values per event): \(threads)")

            #expect(returned < 0.05, "beginFindString returns immediately")
            #expect(findingRightAfter)
            #expect(matches.count == expectedMatches)
            // A delegate implementing didMatchString: replaces the match notifications.
            #expect(counts[viaDelegate ? "match" : "delegateMatch"] == nil)
            #expect(counts["begin"] == 1 && counts["end"] == 1)
            #expect(counts["endPage"] == 2400)
            #expect(firstMatch < end / 4, "results arrive progressively")
            #expect(matchesBeforeHalf > 0 && matchesBeforeHalf < matches.count)
            #expect(threads.values.allSatisfy { $0 == [true] }, "every callback arrives on the main thread")
            #expect(maxGap < 0.25, "main thread stays responsive (loose bound)")
        }

        @Test func synchronousFindForComparison() throws {
            let document = try #require(PDFDocument(data: BigPDF.pages2400))
            let start = monotonicSeconds()
            let results = document.findString(BigPDF.needle, withOptions: .caseInsensitive)
            let seconds = monotonicSeconds() - start
            SpikeLog.note("Q10", String(format: "synchronous findString on 2,400 pages: %.3f s, %d results (blocks the calling thread)", seconds, results.count))
            #expect(results.count == BigPDF.needlePages(pageCount: 2400, every: 50).count)
        }

        /// B8 asks for case- and accent-insensitive matching by default.
        @Test func diacriticInsensitiveOption() throws {
            let data = NSMutableData()
            var box = CGRect(x: 0, y: 0, width: 612, height: 792)
            let context = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
            context.beginPDFPage(nil)
            let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Café crème naïve", attributes: [.init(kCTFontAttributeName as String): font]))
            context.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(line, context)
            context.endPDFPage()
            context.closePDF()
            let document = try #require(PDFDocument(data: data as Data))
            let plain = document.findString("cafe", withOptions: .caseInsensitive).count
            let folded = document.findString("cafe", withOptions: [.caseInsensitive, .diacriticInsensitive]).count
            let naive = document.findString("NAIVE", withOptions: [.caseInsensitive, .diacriticInsensitive]).count
            SpikeLog.note("Q10", "\"cafe\" caseInsensitive=\(plain) +diacriticInsensitive=\(folded); \"NAIVE\" folded=\(naive)")
            #expect(plain == 0)
            #expect(folded == 1)
            #expect(naive == 1)
        }
    }
}

import AppKit
import ObjectiveC
import PDFKit
import Testing

extension M0bSpikes {
    @Suite struct ZProbe {
        @Test func probeQueuedEventLocations() throws {
            let document = try #require(PDFDocument(data: SpikeFixtures.links()))
            let view = ProbePDFView(frame: .zero)
            let host = OffscreenHost(content: view)
            defer { host.close() }
            view.spikeLoad(document)
            let annotation = try #require(document.page(at: 0)?.annotations.first { $0.contents == "goto-explicit" })
            let point = view.windowPoint(centerOf: annotation)

            let ns = Synth.mouse(.leftMouseUp, at: point, in: host.window)
            NSApp.postEvent(ns, atStart: true)
            let nsBack = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true)
            let cg = Synth.cgMouse(.leftMouseUp, at: point, in: host.window)
            SpikeLog.note("probe", "cg event before post: loc=\(cg.locationInWindow) window=\(String(describing: cg.window)) num=\(cg.windowNumber)")
            NSApp.postEvent(cg, atStart: true)
            let cgBack = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true)
            SpikeLog.note("probe", "wanted \(point); NSEvent round trip=\(String(describing: nsBack?.locationInWindow)); CGEvent round trip=\(String(describing: cgBack?.locationInWindow)) win=\(String(describing: cgBack?.windowNumber))")

            // Default PDFKit click with the CG-backed mouse-up queued.
            let target = try #require(Synth.hitView(at: point, in: host.window))
            NSApp.postEvent(Synth.cgMouse(.leftMouseUp, at: point, in: host.window), atStart: true)
            target.mouseDown(with: Synth.mouse(.leftMouseDown, at: point, in: host.window))
            let left = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true)
            SpikeLog.note("probe", "default click with CG up queued: perform=\(view.performed) page=\(document.index(for: view.currentPage!)) upLeft=\(left != nil)")
        }
    }
}

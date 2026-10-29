import AppKit
import ObjectiveC
import PDFKit
import Testing

extension M0bSpikes {
    @Suite struct ZProbe {
        func methods(_ name: String, matching words: [String]) -> [String] {
            guard let cls = NSClassFromString(name) else { return ["<no class \(name)>"] }
            var count: UInt32 = 0
            guard let list = class_copyMethodList(cls, &count) else { return [] }
            defer { free(list) }
            return (0..<Int(count)).map { NSStringFromSelector(method_getName(list[$0])) }
                .filter { sel in words.contains { sel.lowercased().contains($0) } }
                .sorted()
        }

        @Test func probeMethods() {
            for cls in ["PDFView", "PDFPageView", "PDFDocumentView", "PDFScrollView", "PDFClipView", "PDFViewController"] {
                SpikeLog.note("probe", "\(cls): \(methods(cls, matching: ["mouse", "click", "link", "action", "key", "tab", "pressure", "quicklook", "tracking", "hittest", "firstmouse", "menu", "immediate", "drag"]))")
            }
        }

        func pump(_ seconds: TimeInterval) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true) {
                    NSApp.sendEvent(event)
                }
            }
        }

        @Test func probeClickPath() throws {
            WorkspaceTripwire.shared.install()
            WorkspaceTripwire.shared.reset()
            let document = try #require(PDFDocument(data: SpikeFixtures.links()))
            let view = ProbePDFView(frame: .zero)
            let delegate = ProbeViewDelegate()
            view.delegate = delegate
            let host = OffscreenHost(content: view)
            defer { host.close() }
            view.spikeLoad(document)
            let annotation = try #require(document.page(at: 0)?.annotations.first { $0.contents == "goto-explicit" })
            let point = view.windowPoint(centerOf: annotation)

            // D: post both and pump the real NSApp event loop
            NSApp.postEvent(Synth.mouse(.leftMouseDown, at: point, in: host.window), atStart: false)
            NSApp.postEvent(Synth.mouse(.leftMouseUp, at: point, in: host.window), atStart: false)
            pump(1.0)
            SpikeLog.note("probe", "D pump: page=\(document.index(for: view.currentPage!)) perform=\(view.performed) goTo=\(view.wentTo) delegate=\(delegate.calls) downs=\(view.mouseDowns)")

            // E: direct calls on the PDFView
            view.go(to: document.page(at: 0)!)
            Spin.runLoop(0.2)
            let up = Synth.mouse(.leftMouseUp, at: point, in: host.window)
            NSApp.postEvent(up, atStart: true)
            view.mouseDown(with: Synth.mouse(.leftMouseDown, at: point, in: host.window))
            let leftover = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true)
            if let leftover { view.mouseUp(with: leftover) }
            Spin.runLoop(0.5)
            SpikeLog.note("probe", "E direct: leftoverUp=\(leftover != nil) page=\(document.index(for: view.currentPage!)) perform=\(view.performed) goTo=\(view.wentTo) delegate=\(delegate.calls) downs=\(view.mouseDowns)")

            // F: direct mouseDown on the PDFPageView
            view.go(to: document.page(at: 0)!)
            Spin.runLoop(0.2)
            let pageView = host.window.contentView!.hitTest(point)!
            NSApp.postEvent(Synth.mouse(.leftMouseUp, at: point, in: host.window), atStart: true)
            pageView.mouseDown(with: Synth.mouse(.leftMouseDown, at: point, in: host.window))
            let leftover2 = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true)
            if let leftover2 { pageView.mouseUp(with: leftover2) }
            Spin.runLoop(0.5)
            SpikeLog.note("probe", "F pageView: hit=\(type(of: pageView)) leftoverUp=\(leftover2 != nil) page=\(document.index(for: view.currentPage!)) perform=\(view.performed) goTo=\(view.wentTo) delegate=\(delegate.calls) downs=\(view.mouseDowns)")
        }
    }
}

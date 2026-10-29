import AppKit
import ObjectiveC
import PDFKit
import Testing

/// Prototype of the hover layer: its own tracking area, a hover delay, and
/// Force Click through pressure events.
final class HoverPDFView: PDFView {
    private(set) var hoverArea: NSTrackingArea?
    private(set) var events: [String] = []
    private(set) var previews: [LinkTarget] = []
    private(set) var pressureStages: [Int] = []
    var hoverDelay: TimeInterval = 0.5
    private var hoverTimer: Timer?
    private var hoveredTarget: LinkTarget?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: ["lectern": "hover"]
        )
        addTrackingArea(area)
        hoverArea = area
    }

    func linkTarget(atWindowPoint point: NSPoint) -> LinkTarget? {
        let inView = convert(point, from: nil)
        guard let page = page(for: inView, nearest: false),
              let annotation = page.annotation(at: convert(inView, to: page)) else { return nil }
        return LinkClassifier.classify(annotation)
    }

    override func mouseEntered(with event: NSEvent) {
        events.append("entered ours=\(event.trackingArea === hoverArea && hoverArea != nil)")
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        events.append("exited ours=\(event.trackingArea === hoverArea && hoverArea != nil)")
        cancelHover()
        super.mouseExited(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        events.append("moved")
        let target = linkTarget(atWindowPoint: event.locationInWindow)
        if target != hoveredTarget {
            cancelHover()
            hoveredTarget = target
            if let target {
                hoverTimer = Timer.scheduledTimer(withTimeInterval: hoverDelay, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.previews.append(target) }
                }
            }
        }
        super.mouseMoved(with: event)
    }

    private func cancelHover() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        hoveredTarget = nil
    }

    override func pressureChange(with event: NSEvent) {
        pressureStages.append(event.stage)
        super.pressureChange(with: event)
    }
}

extension M0bSpikes {
    /// Q8: hover through an NSTrackingArea, and Force Click (pressure).
    @Suite struct Q8Hover {
        func hosted() throws -> (HoverPDFView, OffscreenHost, PDFDocument) {
            let document = try #require(PDFDocument(data: SpikeFixtures.links()))
            let view = HoverPDFView(frame: .zero)
            let host = OffscreenHost(content: view)
            view.spikeLoad(document)
            return (view, host, document)
        }

        func linkPoint(_ tag: String, _ view: PDFView, _ document: PDFDocument) throws -> NSPoint {
            view.windowPoint(centerOf: try #require(document.page(at: 0)?.annotations.first { $0.contents == tag }))
        }

        @Test func trackingAreaIsInstalled() throws {
            let (view, host, _) = try hosted()
            defer { host.close() }
            let ours = view.trackingAreas.filter { $0 === view.hoverArea }
            let theirs = view.trackingAreas.filter { $0 !== view.hoverArea }
            SpikeLog.note("Q8", "tracking areas: ours=\(ours.count) PDFView's own=\(theirs.map { "rect=\($0.rect) options=\($0.options.rawValue)" })")
            #expect(ours.count == 1)
        }

        /// Synthesised events sent through the window: what reaches the view?
        @Test func syntheticEventsThroughTheWindow() throws {
            let (view, host, document) = try hosted()
            defer { host.close() }
            let point = try linkPoint("uri-https", view, document)
            let moved = { host.window.sendEvent(Synth.mouse(.mouseMoved, at: point, in: host.window, clickCount: 0)) }

            host.window.makeFirstResponder(view)
            moved()
            let asFirstResponder = view.events
            host.window.makeFirstResponder(nil)
            moved()
            let notFirstResponder = Array(view.events.dropFirst(asFirstResponder.count))

            let entered = NSEvent.enterExitEvent(
                with: .mouseEntered, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: host.window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
            )!
            let before = view.events.count
            host.window.sendEvent(entered)
            Spin.runLoop(0.2)
            let afterEntered = Array(view.events.dropFirst(before))
            SpikeLog.note("Q8", "window.sendEvent(mouseMoved): as first responder=\(asFirstResponder) not first responder=\(notFirstResponder); synthetic mouseEntered=\(afterEntered); hover previews=\(view.previews)")
            // A synthetic mouseMoved reaches the view only as first responder
            // (window → first responder routing), not via the tracking area;
            // a synthetic mouseEntered never arrives. Tracking-area delivery
            // is driven by the window server's cursor and can't be tested here.
            #expect(asFirstResponder == ["moved"])
            #expect(notFirstResponder.isEmpty)
            #expect(afterEntered.isEmpty)
        }

        @Test func hoverDelayLogicGivenEvents() throws {
            let (view, host, document) = try hosted()
            defer { host.close() }
            let link = try linkPoint("goto-explicit", view, document)
            let other = try linkPoint("uri-https", view, document)
            let blank = view.windowPoint(CGPoint(x: 560, y: 60), on: document.page(at: 0)!)
            func move(_ p: NSPoint) { view.mouseMoved(with: Synth.mouse(.mouseMoved, at: p, in: host.window, clickCount: 0)) }

            move(link)
            Spin.runLoop(0.2)
            move(blank)              // left before the delay: no preview
            Spin.runLoop(0.6)
            #expect(view.previews.isEmpty)

            move(other)
            Spin.runLoop(0.7)        // stayed past the delay: preview
            #expect(view.previews == [.web(URL(string: "https://lectern-probe.invalid/page")!)])
            #expect(view.areaOfInterest(for: view.convert(other, from: nil)).contains(.linkArea))
        }

        @Test func forceClickAPI() throws {
            let (view, host, _) = try hosted()
            defer { host.close() }
            let pressure = NSSelectorFromString("pressureChangeWithEvent:")
            let quickLook = NSSelectorFromString("quickLookWithEvent:")
            let pdfOverridesPressure = Runtime.overrides(PDFView.self, pressure, from: NSView.self)
            let pdfOverridesQuickLook = Runtime.overrides(PDFView.self, quickLook, from: NSView.self)
            let immediate = view.gestureRecognizers.filter { String(describing: type(of: $0)) == "NSImmediateActionGestureRecognizer" }
            SpikeLog.note("Q8", "PDFView overrides pressureChangeWithEvent:=\(pdfOverridesPressure) quickLookWithEvent:=\(pdfOverridesQuickLook) immediateActionRecognizers=\(immediate.count) delegate=\(String(describing: immediate.first?.delegate.map { type(of: $0) }))")
            #expect(view.responds(to: pressure))
            #expect(!pdfOverridesPressure, "PDFView leaves pressureChangeWithEvent: to subclasses")
            #expect(immediate.count == 1, "PDFView installs an immediate-action (Force Click / Look Up) recognizer")
            // The reader can remove it, so Force Click goes only to pressureChange.
            immediate.forEach(view.removeGestureRecognizer)
            #expect(!view.gestureRecognizers.contains { String(describing: type(of: $0)) == "NSImmediateActionGestureRecognizer" })
            view.pressureConfiguration = NSPressureConfiguration(pressureBehavior: .primaryDeepClick)
            #expect(view.pressureConfiguration != nil)

            // No supported way to build a pressure event: NSEvent has no
            // factory for it, and NSEvent(cgEvent:) on a CGEvent retyped to 34
            // crashed the test host when tried during this spike.
            #expect(NSEvent.EventType.pressure.rawValue == 34)
        }
    }
}

import AppKit
import PDFKit
import Testing

extension M0bSpikes {
    /// Q1: does PDFKit ever execute document JavaScript? The fixture's
    /// scripts each write "JS_RAN" into their own output field (and the
    /// OpenAction also moves to page 2), so any execution is observable in
    /// the model, in the serialised bytes, or in the view.
    @Suite struct Q1JavaScript {
        func fields(_ document: PDFDocument) -> [String: String] {
            var values: [String: String] = [:]
            for annotation in document.page(at: 0)?.annotations ?? [] {
                if let name = annotation.fieldName { values[name] = annotation.widgetStringValue ?? "nil" }
            }
            return values
        }

        func ranAnywhere(_ document: PDFDocument) -> [String] {
            fields(document).filter { $0.value.contains(SpikeFixtures.jsMarker) }.map(\.key).sorted()
        }

        @Test func fixtureIsWellFormed() throws {
            let document = try #require(PDFDocument(data: SpikeFixtures.javaScriptProbe()))
            let values = fields(document)
            #expect(document.pageCount == 2)
            for name in SpikeFixtures.jsOutputs { #expect(values[name] == "INITIAL", "\(name)") }
            #expect(values["n_a"] == "2")
            #expect(values["n_sum"] == "0")
            // The scripts survive in the bytes; the marker itself never appears.
            #expect(!PDFBytes.contains(SpikeFixtures.jsMarker, in: SpikeFixtures.javaScriptProbe()))
            #expect(PDFBytes.contains("/S /JavaScript", in: SpikeFixtures.javaScriptProbe()))
        }

        @Test func noJavaScriptRunsOnLoadDisplayClickFocusTypeOrBlur() throws {
            WorkspaceTripwire.shared.install()
            WorkspaceTripwire.shared.reset()
            let document = try #require(PDFDocument(data: SpikeFixtures.javaScriptProbe()))
            #expect(ranAnywhere(document).isEmpty, "after load")

            let view = ProbePDFView(frame: .zero)
            let delegate = ProbeViewDelegate()
            view.delegate = delegate
            let host = OffscreenHost(content: view)
            defer { host.close() }
            view.spikeLoad(document, mode: .singlePage)
            view.display()
            Spin.runLoop(0.5)
            #expect(ranAnywhere(document).isEmpty, "after display")
            #expect(view.currentPage.map { document.index(for: $0) } == 0, "OpenAction's this.pageNum = 1 did not run")

            // Link with a JavaScript action.
            let page = try #require(document.page(at: 0))
            let link = try #require(page.annotations.first { $0.contents == "js-link" })
            Synth.click(at: view.windowPoint(centerOf: link), in: host.window)
            Spin.runLoop(0.3)
            SpikeLog.note("Q1", "link click: perform=\(view.performed) page=\(document.index(for: view.currentPage!))")
            #expect(view.performed == ["JavaScript"], "PDFView.performAction: was called with the JavaScript action")
            #expect(ranAnywhere(document).isEmpty, "after JavaScript link click")

            // Focus (/Fo), mouse up (/U), keystroke (/K) and blur (/Bl) on the trigger field.
            let trigger = try #require(page.annotations.first { $0.fieldName == "trigger" })
            Synth.click(at: view.windowPoint(centerOf: trigger), in: host.window)
            Spin.runLoop(0.3)
            let responder = host.window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            Synth.type("xyz", in: host.window)
            Synth.key("\r", keyCode: Synth.returnKeyCode, in: host.window)
            let blank = CGPoint(x: 560, y: 60) // empty area of page 1
            Synth.click(at: view.windowPoint(blank, on: page), in: host.window)
            Spin.runLoop(0.3)
            let triggerValue = trigger.widgetStringValue ?? "nil"
            SpikeLog.note("Q1", "trigger field: firstResponder while editing=\(responder) value after typing=\(triggerValue)")
            SpikeLog.note("Q1", "fields after all stimuli: \(fields(document))")
            #expect(ranAnywhere(document).isEmpty, "after focus/keystroke/blur")

            // Changing a field that a calculate script depends on.
            let a = try #require(page.annotations.first { $0.fieldName == "n_a" })
            a.widgetStringValue = "7"
            Spin.runLoop(0.2)
            #expect(fields(document)["n_sum"] == "0", "AFSimple_Calculate did not run")

            // Nothing in the serialised file either.
            let data = try #require(document.dataRepresentation())
            #expect(!PDFBytes.contains(SpikeFixtures.jsMarker, in: data))
            #expect(WorkspaceTripwire.shared.calls.isEmpty)
            #expect(delegate.calls.isEmpty)
        }

        @Test func dataRepresentationStripsDocumentJavaScript() throws {
            let document = try #require(PDFDocument(data: SpikeFixtures.javaScriptProbe()))
            let data = try #require(document.dataRepresentation())
            SpikeArtifacts.save(SpikeFixtures.javaScriptProbe(), as: "q1-javascript-original.pdf")
            SpikeArtifacts.save(data, as: "q1-javascript-rewritten.pdf")
            let names = ["/OpenAction", "/JavaScript", "/JS", "/AA", "/A", "/Names", "/CO"]
            let original = SpikeFixtures.javaScriptProbe()
            #expect(names.allSatisfy { PDFBytes.containsName($0, in: original) })
            let kept = names.filter { PDFBytes.containsName($0, in: data) }
                + ["AFSimple_Calculate", "AFNumber_Format"].filter { PDFBytes.contains($0, in: data) }
            SpikeLog.note("Q1", "JavaScript-related entries kept by dataRepresentation(): \(kept)")
            // Every action is gone: OpenAction, document scripts, page and
            // field additional-actions, the link's /A, and the calculation order.
            #expect(kept.isEmpty)
            // The link annotation itself survives, without its action.
            let reloaded = try #require(PDFDocument(data: data))
            let link = reloaded.page(at: 0)?.annotations.first { $0.type == "Link" }
            #expect(link != nil)
            #expect(link?.action == nil)
        }
    }
}

import AppKit
import PDFKit
import Testing

/// Prototype for A5: widgets stay non-editable because the view swallows
/// the events that would start editing. `isReadOnly` is never touched.
final class FormBlockingPDFView: PDFView {
    private(set) var swallowed: [String] = []

    func widget(atWindowPoint point: NSPoint) -> PDFAnnotation? {
        let inView = convert(point, from: nil)
        guard let page = page(for: inView, nearest: false),
              let annotation = page.annotation(at: convert(inView, to: page)),
              annotation.type == "Widget" else { return nil }
        return annotation
    }

    override func mouseDown(with event: NSEvent) {
        if let widget = widget(atWindowPoint: event.locationInWindow) {
            swallowed.append("mouseDown \(widget.fieldName ?? "?")")
            return
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // Tab / Shift-Tab are how PDFView moves focus into form fields; the
        // reader uses them for link focus instead.
        if event.keyCode == Synth.tabKeyCode {
            swallowed.append("tab")
            return
        }
        super.keyDown(with: event)
    }
}

extension M0bSpikes {
    /// Q3: can widget editing be blocked without isReadOnly? Does focus or
    /// Tab still reach fields? Does isReadOnly change dataRepresentation()?
    @Suite struct Q3Forms {
        struct Hosted<V: PDFView> {
            let view: V
            let host: OffscreenHost
            let document: PDFDocument
            func field(_ name: String) -> PDFAnnotation { document.page(at: 0)!.annotations.first { $0.fieldName == name }! }
            var responder: String { host.window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil" }
            var editing: Bool { responder == "PDFTextWidgetTextView" }
        }

        func host<V: PDFView>(_ view: V) throws -> Hosted<V> {
            let document = try #require(PDFDocument(data: SpikeFixtures.form()))
            let host = OffscreenHost(content: view)
            view.spikeLoad(document, mode: .singlePage)
            host.window.makeFirstResponder(view)
            return Hosted(view: view, host: host, document: document)
        }

        @Test func fixture() throws {
            let document = try #require(PDFDocument(data: SpikeFixtures.form()))
            let fields = document.page(at: 0)!.annotations.filter { $0.type == "Widget" }
            #expect(fields.map { $0.fieldName ?? "" }.sorted() == ["agree", "city", "name"])
            #expect(fields.first { $0.fieldName == "agree" }?.buttonWidgetState == .offState)
            #expect(fields.allSatisfy { !$0.isReadOnly })
        }

        @Test func stockPDFViewEditsFieldsOnClick() throws {
            let h = try host(PDFView(frame: .zero))
            defer { h.host.close() }
            Synth.click(at: h.view.windowPoint(centerOf: h.field("name")), in: h.host.window)
            Spin.runLoop(0.2)
            let responderAfterClick = h.responder
            Synth.type("Z", in: h.host.window)
            Synth.click(at: h.view.windowPoint(centerOf: h.field("agree")), in: h.host.window)
            Spin.runLoop(0.2)
            SpikeLog.note("Q3", "stock: responder after click=\(responderAfterClick) name=\(h.field("name").widgetStringValue ?? "nil") agree=\(h.field("agree").buttonWidgetState.rawValue)")
            #expect(responderAfterClick == "PDFTextWidgetTextView")
            #expect(h.field("name").widgetStringValue == "AliceZ")
            #expect(h.field("agree").buttonWidgetState == .onState)
        }

        @Test func stockPDFViewTabMovesFocusIntoFields() throws {
            let h = try host(PDFView(frame: .zero))
            defer { h.host.close() }
            #expect(h.responder == "PDFView")
            Synth.key("\t", keyCode: Synth.tabKeyCode, in: h.host.window)
            Spin.runLoop(0.2)
            let afterTab = h.responder
            Synth.type("Q", in: h.host.window)
            let values = ["name": h.field("name").widgetStringValue ?? "", "city": h.field("city").widgetStringValue ?? ""]
            SpikeLog.note("Q3", "stock: responder after Tab=\(afterTab) values after typing=\(values)")
            // Tab from the PDFView itself does not enter a field.
            #expect(afterTab == "PDFView")
            #expect(values == ["name": "Alice", "city": "Paris"])
        }

        @Test func stockPDFViewTabInsideAFieldMovesToTheNextField() throws {
            let h = try host(PDFView(frame: .zero))
            defer { h.host.close() }
            Synth.click(at: h.view.windowPoint(centerOf: h.field("name")), in: h.host.window)
            Spin.runLoop(0.2)
            Synth.key("\t", keyCode: Synth.tabKeyCode, in: h.host.window)
            Spin.runLoop(0.2)
            let afterTab = h.responder
            Synth.type("Q", in: h.host.window)
            Spin.runLoop(0.1)
            let values = ["name": h.field("name").widgetStringValue ?? "", "city": h.field("city").widgetStringValue ?? ""]
            SpikeLog.note("Q3", "stock: Tab while editing name → responder=\(afterTab) values=\(values)")
            // Observed with a synthesised Tab sent to the field editor: focus
            // stays in the same field and no tab is inserted. (PDFView has
            // private Tab handlers for widgets; a real keyboard may differ.
            // Moot for A5: the blocking view never lets a field take focus.)
            #expect(afterTab == "PDFTextWidgetTextView")
            #expect(values == ["name": "AliceQ", "city": "Paris"])
        }

        @Test func blockingViewPreventsClickAndTabEditing() throws {
            let h = try host(FormBlockingPDFView(frame: .zero))
            defer { h.host.close() }
            Synth.click(at: h.view.windowPoint(centerOf: h.field("name")), in: h.host.window)
            Synth.type("Z", in: h.host.window)
            Synth.click(at: h.view.windowPoint(centerOf: h.field("agree")), in: h.host.window)
            Synth.key("\t", keyCode: Synth.tabKeyCode, in: h.host.window)
            Synth.type("Q", in: h.host.window)
            Spin.runLoop(0.2)
            SpikeLog.note("Q3", "blocking: responder=\(h.responder) swallowed=\(h.view.swallowed) name=\(h.field("name").widgetStringValue ?? "nil") city=\(h.field("city").widgetStringValue ?? "nil") agree=\(h.field("agree").buttonWidgetState.rawValue)")
            #expect(!h.editing)
            #expect(h.responder == "FormBlockingPDFView")
            #expect(h.view.swallowed == ["mouseDown name", "mouseDown agree", "tab"])
            #expect(h.field("name").widgetStringValue == "Alice")
            #expect(h.field("city").widgetStringValue == "Paris")
            #expect(h.field("agree").buttonWidgetState == .offState)
            #expect(h.field("name").isReadOnly == false, "the model is untouched")
            // The rewritten bytes keep the original values.
            let data = try #require(h.document.dataRepresentation())
            #expect(PDFBytes.contains("/V (Alice)", in: data))
        }

        func flags(_ data: Data) -> [String: String] {
            var result: [String: String] = [:]
            for body in PDFBytes.objects(containing: "/Subtype /Widget", in: data) {
                guard let name = body.range(of: "/T \\([a-z]+\\)", options: .regularExpression).map({ String(body[$0]) }) else { continue }
                let ff = body.range(of: "/Ff [0-9]+", options: .regularExpression).map { String(body[$0]) } ?? "none"
                result[name] = ff
            }
            return result
        }

        @Test func isReadOnlyChangesTheSerialisedFieldFlags() throws {
            let original = SpikeFixtures.form()
            #expect(!PDFBytes.containsName("/Ff", in: original))
            let plain = try #require(PDFDocument(data: original))
            let plainFlags = flags(try #require(plain.dataRepresentation()))

            let locked = try #require(PDFDocument(data: original))
            for annotation in locked.page(at: 0)!.annotations where annotation.type == "Widget" { annotation.isReadOnly = true }
            let lockedFlags = flags(try #require(locked.dataRepresentation()))
            SpikeLog.note("Q3", "/Ff after rewrite: untouched=\(plainFlags) isReadOnly=\(lockedFlags)")
            #expect(plainFlags.values.allSatisfy { $0 == "/Ff 0" }, "the rewrite adds /Ff 0 even when nothing changed")
            #expect(lockedFlags.values.allSatisfy { $0 == "/Ff 1" }, "isReadOnly is written as the ReadOnly bit")
        }

        @Test func isReadOnlyAlsoBlocksEditingInAStockView() throws {
            let h = try host(PDFView(frame: .zero))
            defer { h.host.close() }
            for annotation in h.document.page(at: 0)!.annotations where annotation.type == "Widget" { annotation.isReadOnly = true }
            Synth.click(at: h.view.windowPoint(centerOf: h.field("name")), in: h.host.window)
            Synth.type("Z", in: h.host.window)
            Synth.click(at: h.view.windowPoint(centerOf: h.field("agree")), in: h.host.window)
            SpikeLog.note("Q3", "isReadOnly stock: responder=\(h.responder) name=\(h.field("name").widgetStringValue ?? "nil") agree=\(h.field("agree").buttonWidgetState.rawValue)")
            #expect(h.field("name").widgetStringValue == "Alice")
            #expect(h.field("agree").buttonWidgetState == .offState)
        }
    }
}

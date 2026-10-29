import Foundation

/// Hand-written fixtures. Every external target is inert: unregistered URL
/// schemes, `.invalid` hosts, and paths that don't exist.
nonisolated enum SpikeFixtures {
    // MARK: Q1 JavaScript

    /// Value every JavaScript trigger would write. It is built by
    /// concatenation in the scripts, so it never appears in the file unless a
    /// script actually ran and the result was stored.
    static let jsMarker = "JS_RAN"

    /// Output fields, each written by exactly one JavaScript trigger.
    static let jsOutputs = [
        "out_open",      // catalog /OpenAction
        "out_doc",       // document-level /Names /JavaScript
        "out_page",      // page /AA /O (page open)
        "out_link",      // link annotation /A JavaScript
        "out_focus",     // trigger field /AA /Fo
        "out_keystroke", // trigger field /AA /K
        "out_mouseup",   // trigger field /AA /U
        "out_blur",      // trigger field /AA /Bl
        "out_calc",      // /AA /C calculate, plain JavaScript
    ]

    static func js(_ source: String) -> String {
        "<< /S /JavaScript /JS (\(RawPDF.escape(source))) >>"
    }

    static func setField(_ name: String) -> String {
        js("this.getField(\"\(name)\").value = \"JS\" + \"_RAN\";")
    }

    static func javaScriptProbe() -> Data {
        var objects: [Int: String] = [:]
        // Field layout on page 1: two columns of boxes.
        let names = jsOutputs + ["n_a", "n_sum", "trigger"]
        var fieldRefs: [String] = []
        for (index, name) in names.enumerated() {
            let num = 20 + index
            fieldRefs.append("\(num) 0 R")
            let column = index % 2, row = index / 2
            let x = 72 + column * 250, y = 700 - row * 50
            var value = "INITIAL"
            var extra = ""
            switch name {
            case "out_calc":
                extra = "/AA << /C \(js("event.value = \"JS\" + \"_RAN\";")) >>"
            case "n_a":
                value = "2"
                extra = "/AA << /F \(js("AFNumber_Format(2, 0, 0, 0, \"\", true);")) /K \(js("AFNumber_Keystroke(2, 0, 0, 0, \"\", true);")) >>"
            case "n_sum":
                value = "0"
                extra = "/AA << /C \(js("AFSimple_Calculate(\"SUM\", new Array(\"n_a\"));")) >>"
            case "trigger":
                extra = "/AA << /Fo \(setField("out_focus")) /K \(setField("out_keystroke")) /U \(setField("out_mouseup")) /Bl \(setField("out_blur")) >>"
            default:
                break
            }
            objects[num] = "<< /Type /Annot /Subtype /Widget /FT /Tx /T (\(name)) /V (\(value)) /Rect [\(x) \(y) \(x + 200) \(y + 30)] /P 3 0 R /F 4 /DA (/Helv 12 Tf 0 g) /MK << /BG [0.9 0.9 0.9] >> \(extra) >>"
        }
        let calcOrder = "[\(20 + names.firstIndex(of: "out_calc")!) 0 R \(20 + names.firstIndex(of: "n_sum")!) 0 R]"
        objects[1] = "<< /Type /Catalog /Pages 2 0 R /OpenAction 40 0 R /Names << /JavaScript 41 0 R >> /AcroForm << /Fields [\(fieldRefs.joined(separator: " "))] /CO \(calcOrder) /DA (/Helv 12 Tf 0 g) /DR << /Font << /Helv 10 0 R >> >> >> /AA << /WC 43 0 R >> >>"
        objects[2] = "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>"
        objects[3] = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 6 0 R /Resources << /Font << /F1 10 0 R >> >> /Annots [\(fieldRefs.joined(separator: " ")) 50 0 R] /AA << /O 42 0 R >> >>"
        objects[4] = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 7 0 R /Resources << /Font << /F1 10 0 R >> >> >>"
        objects[6] = RawPDF.textContent(["JavaScript probe, page 1"], top: 760)
        objects[7] = RawPDF.textContent(["JavaScript probe, page 2"], top: 760)
        objects[10] = RawPDF.helvetica
        objects[50] = "<< /Type /Annot /Subtype /Link /Rect [72 100 300 140] /Border [0 0 1] /Contents (js-link) /A \(setField("out_link")) >>"
        objects[40] = js("this.getField(\"out_open\").value = \"JS\" + \"_RAN\"; this.pageNum = 1;")
        objects[41] = "<< /Names [(lectern) 44 0 R] >>"
        objects[42] = setField("out_page")
        objects[43] = js("var lecternWillClose = 1;")
        objects[44] = setField("out_doc")
        return RawPDF.build(objects: objects, root: 1).data
    }

    // MARK: Q2 action types

    struct LinkSpec: Sendable {
        let tag: String
        let entry: String
        /// Clicking it could open a modal (print panel), so it is only inspected.
        var clickable = true
    }

    /// Links on page 1 of a three-page document. Pages are objects 3, 4, 5.
    static let linkSpecs: [LinkSpec] = [
        LinkSpec(tag: "uri-custom", entry: "/A << /S /URI /URI (lectern-probe-unhandled://uri-link) >>"),
        LinkSpec(tag: "uri-https", entry: "/A << /S /URI /URI (https://lectern-probe.invalid/page) >>"),
        LinkSpec(tag: "goto-explicit", entry: "/A << /S /GoTo /D [5 0 R /XYZ 0 792 0] >>"),
        LinkSpec(tag: "goto-named", entry: "/A << /S /GoTo /D (chapter2) >>"),
        LinkSpec(tag: "dest-fit", entry: "/Dest [4 0 R /Fit]"),
        LinkSpec(tag: "dest-named", entry: "/Dest (chapter2)"),
        LinkSpec(tag: "gotor", entry: "/A << /S /GoToR /F (/nonexistent/lectern-probe.pdf) /D [0 /Fit] >>"),
        LinkSpec(tag: "launch", entry: "/A << /S /Launch /F (/nonexistent/lectern-probe.app) >>"),
        LinkSpec(tag: "submit", entry: "/A << /S /SubmitForm /F << /FS /URL /F (https://lectern-probe.invalid/submit) >> /Flags 4 >>"),
        LinkSpec(tag: "javascript", entry: "/A << /S /JavaScript /JS (var lecternProbe = 1;) >>"),
        LinkSpec(tag: "named-next", entry: "/A << /S /Named /N /NextPage >>"),
        LinkSpec(tag: "named-print", entry: "/A << /S /Named /N /Print >>", clickable: false),
        LinkSpec(tag: "reset-form", entry: "/A << /S /ResetForm >>"),
        LinkSpec(tag: "goto-xyz-null", entry: "/A << /S /GoTo /D [5 0 R /XYZ null null null] >>"),
        LinkSpec(tag: "goto-fith", entry: "/A << /S /GoTo /D [5 0 R /FitH 400] >>"),
        LinkSpec(tag: "goto-fitr", entry: "/A << /S /GoTo /D [5 0 R /FitR 72 72 300 300] >>"),
        LinkSpec(tag: "goto-xyz-zoom", entry: "/A << /S /GoTo /D [5 0 R /XYZ 100 500 2] >>"),
    ]

    static func linkRect(_ index: Int) -> (x: Int, y: Int, w: Int, h: Int) {
        (72, 750 - index * 38, 260, 28)
    }

    static func links() -> Data {
        var objects: [Int: String] = [:]
        var annotRefs: [String] = []
        for (index, spec) in linkSpecs.enumerated() {
            let num = 20 + index
            let r = linkRect(index)
            annotRefs.append("\(num) 0 R")
            objects[num] = "<< /Type /Annot /Subtype /Link /Rect [\(r.x) \(r.y) \(r.x + r.w) \(r.y + r.h)] /Border [0 0 1] /Contents (\(spec.tag)) \(spec.entry) >>"
        }
        objects[1] = "<< /Type /Catalog /Pages 2 0 R /Names << /Dests 9 0 R >> >>"
        objects[2] = "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>"
        objects[3] = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 6 0 R /Resources << /Font << /F1 10 0 R >> >> /Annots [\(annotRefs.joined(separator: " "))] >>"
        objects[4] = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 7 0 R /Resources << /Font << /F1 10 0 R >> >> >>"
        objects[5] = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 8 0 R /Resources << /Font << /F1 10 0 R >> >> >>"
        objects[6] = RawPDF.textContent(linkSpecs.map(\.tag), x: 340, top: 758, size: 12)
        objects[7] = RawPDF.textContent(["Page 2 (chapter2)"])
        objects[8] = RawPDF.textContent(["Page 3"])
        objects[9] = "<< /Names [(chapter2) [4 0 R /XYZ 72 600 null]] >>"
        objects[10] = RawPDF.helvetica
        return RawPDF.build(objects: objects, root: 1).data
    }

    // MARK: Q3 form fields

    /// Two text fields and a checkbox (with real On/Off appearances).
    static func form() -> Data {
        var objects: [Int: String] = [:]
        objects[1] = "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [20 0 R 21 0 R 22 0 R] /DA (/Helv 12 Tf 0 g) /DR << /Font << /Helv 10 0 R >> >> >> >>"
        objects[2] = "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"
        objects[3] = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 10 0 R >> >> /Annots [20 0 R 21 0 R 22 0 R] >>"
        objects[4] = RawPDF.textContent(["Form probe"], top: 760)
        objects[10] = RawPDF.helvetica
        objects[20] = "<< /Type /Annot /Subtype /Widget /FT /Tx /T (name) /V (Alice) /Rect [72 650 300 680] /P 3 0 R /F 4 /DA (/Helv 12 Tf 0 g) >>"
        objects[21] = "<< /Type /Annot /Subtype /Widget /FT /Tx /T (city) /V (Paris) /Rect [72 600 300 630] /P 3 0 R /F 4 /DA (/Helv 12 Tf 0 g) >>"
        objects[22] = "<< /Type /Annot /Subtype /Widget /FT /Btn /T (agree) /V /Off /AS /Off /Rect [72 550 92 570] /P 3 0 R /F 4 /MK << /CA (4) >> /DA (/ZaDb 12 Tf 0 g) /AP << /N << /Yes 30 0 R /Off 31 0 R >> >> >>"
        objects[30] = RawPDF.stream("0 0 0 rg 4 4 12 12 re f", dict: "/Type /XObject /Subtype /Form /BBox [0 0 20 20]")
        objects[31] = RawPDF.stream("", dict: "/Type /XObject /Subtype /Form /BBox [0 0 20 20]")
        return RawPDF.build(objects: objects, root: 1).data
    }

    // MARK: Q6 incremental update

    static let originalID = "0123456789ABCDEF0123456789ABCDEF"
    static let updatedID = "FEDCBA9876543210FEDCBA9876543210"

    /// A two-revision file: the base revision, then an incremental update
    /// that replaces the page content and the Info dictionary.
    static func incremental() -> (base: Data, updated: Data) {
        var objects: [Int: String] = [:]
        objects[1] = "<< /Type /Catalog /Pages 2 0 R /OpenAction [3 0 R /Fit] /LecternCatalogKey (catalog-custom-marker) /PageLabels << /Nums [0 << /S /r >>] >> /AcroForm << /Fields [8 0 R] /DA (/Helv 12 Tf 0 g) /DR << /Font << /Helv 5 0 R >> >> >> >>"
        objects[2] = "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"
        objects[3] = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> /Annots [8 0 R] /LecternPageKey (page-custom-marker) >>"
        objects[4] = RawPDF.textContent(["Revision one text"])
        objects[5] = RawPDF.helvetica
        objects[6] = "<< /Title (Original Title) /Producer (Lectern raw writer) /LecternInfoKey (info-custom-marker) >>"
        objects[7] = "(orphan-object-marker)"
        objects[8] = "<< /Type /Annot /Subtype /Widget /FT /Tx /T (name) /V (form-value-marker) /Rect [72 500 300 530] /P 3 0 R /F 4 /DA (/Helv 12 Tf 0 g) >>"
        let base = RawPDF.build(
            objects: objects, root: 1, info: 6,
            trailerExtra: "/ID [<\(originalID)> <\(originalID)>] /LecternTrailerKey (trailer-custom-marker)",
            comment: "lectern-comment-marker"
        )
        let updated = RawPDF.appendUpdate(
            to: base,
            objects: [
                4: RawPDF.textContent(["Revision two text"]),
                6: "<< /Title (Updated Title) /Producer (Lectern raw writer) /LecternInfoKey (info-custom-marker) >>",
            ],
            root: 1, info: 6,
            trailerExtra: "/ID [<\(originalID)> <\(updatedID)>]"
        )
        return (base.data, updated.data)
    }
}

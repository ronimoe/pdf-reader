import AppKit
import CoreText
import Foundation
import PDFKit
import Testing

/// Parent suite for the M0b PDFKit spikes. Everything runs serialized: the
/// tests share the main run loop, a process-wide NSWorkspace tripwire, and
/// some of them take timing measurements.
@Suite(.serialized, .timeLimit(.minutes(5)), .noUI)
struct M0bSpikes {}

/// Observations are printed with a fixed prefix so a run can be grepped:
/// `xcodebuild … test 2>&1 | grep 'M0B|'`.
nonisolated enum SpikeLog {
    static func note(_ question: String, _ message: String) {
        print("M0B| \(question) | \(message)")
    }
}

// MARK: - Raw PDF authoring

/// Writes PDF syntax by hand, for fixtures PDFKit can't author (JavaScript,
/// Launch, GoToR, SubmitForm actions; incremental updates; orphan objects).
nonisolated struct SpikeRawPDF {
    struct Built {
        var data: Data
        var xrefOffset: Int
        var size: Int
    }

    /// A stream object body with a correct /Length.
    static func stream(_ content: String, dict: String = "") -> String {
        "<< /Length \(content.utf8.count) \(dict) >>\nstream\n\(content)\nendstream"
    }

    /// A content stream that writes one or more lines of Helvetica text.
    static func textContent(_ lines: [String], x: Int = 72, top: Int = 720, size: Int = 18) -> String {
        var ops = "BT /F1 \(size) Tf \(size + 6) TL \(x) \(top) Td\n"
        for line in lines { ops += "(\(escape(line))) Tj T*\n" }
        ops += "ET"
        return stream(ops)
    }

    /// Escapes a PDF literal string body.
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
    }

    static let helvetica = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"

    /// Builds a complete single-revision file.
    static func build(
        objects: [Int: String],
        root: Int,
        info: Int? = nil,
        trailerExtra: String = "",
        comment: String? = nil
    ) -> Built {
        var out = Data("%PDF-1.7\n".utf8)
        out.append(contentsOf: [0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A])
        if let comment { out.append(Data("%\(comment)\n".utf8)) }
        var offsets: [Int: Int] = [:]
        for num in objects.keys.sorted() {
            offsets[num] = out.count
            out.append(Data("\(num) 0 obj\n\(objects[num]!)\nendobj\n".utf8))
        }
        let size = (objects.keys.max() ?? 0) + 1
        let xrefOffset = out.count
        var xref = "xref\n0 \(size)\n0000000000 65535 f \n"
        for num in 1..<size {
            if let offset = offsets[num] {
                xref += String(format: "%010d 00000 n \n", offset)
            } else {
                xref += "0000000000 00000 f \n"
            }
        }
        out.append(Data(xref.utf8))
        let infoRef = info.map { " /Info \($0) 0 R" } ?? ""
        out.append(Data("trailer\n<< /Size \(size) /Root \(root) 0 R\(infoRef) \(trailerExtra) >>\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8))
        return Built(data: out, xrefOffset: xrefOffset, size: size)
    }

    /// Appends an incremental update (new or replaced objects, a new xref
    /// section, and a trailer whose /Prev points at the previous xref).
    static func appendUpdate(
        to base: Built,
        objects: [Int: String],
        root: Int,
        info: Int? = nil,
        trailerExtra: String = ""
    ) -> Built {
        var out = base.data
        var offsets: [Int: Int] = [:]
        for num in objects.keys.sorted() {
            offsets[num] = out.count
            out.append(Data("\(num) 0 obj\n\(objects[num]!)\nendobj\n".utf8))
        }
        let size = max(base.size, (objects.keys.max() ?? 0) + 1)
        let xrefOffset = out.count
        var xref = "xref\n0 1\n0000000000 65535 f \n"
        for num in objects.keys.sorted() {
            xref += "\(num) 1\n" + String(format: "%010d 00000 n \n", offsets[num]!)
        }
        out.append(Data(xref.utf8))
        let infoRef = info.map { " /Info \($0) 0 R" } ?? ""
        out.append(Data("trailer\n<< /Size \(size) /Root \(root) 0 R\(infoRef) /Prev \(base.xrefOffset) \(trailerExtra) >>\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8))
        return Built(data: out, xrefOffset: xrefOffset, size: size)
    }
}

// MARK: - Inspecting serialised bytes

nonisolated enum PDFBytes {
    static func text(_ data: Data) -> String {
        String(data: data, encoding: .isoLatin1) ?? ""
    }

    /// The file as text with every run of whitespace collapsed to one space.
    /// PDFKit wraps dictionaries across lines (`/Subtype\n/Highlight`), so
    /// every token search works on this form.
    static func flat(_ data: Data) -> String {
        flatten(text(data))
    }

    static func flatten(_ string: String) -> String {
        var out = String.UnicodeScalarView()
        var lastWasSpace = false
        for scalar in string.unicodeScalars {
            let isSpace = scalar == " " || scalar == "\n" || scalar == "\r" || scalar == "\t"
            if isSpace {
                if !lastWasSpace { out.append(" ") }
                lastWasSpace = true
            } else {
                out.append(scalar)
                lastWasSpace = false
            }
        }
        return String(out)
    }

    static func count(_ needle: String, in data: Data) -> Int {
        flat(data).components(separatedBy: needle).count - 1
    }

    static func contains(_ needle: String, in data: Data) -> Bool {
        flat(data).contains(needle)
    }

    /// Whether the PDF name `/Name` occurs as a whole token (so `/AA` does
    /// not match `/AAAAAB+Helvetica`).
    static func containsName(_ name: String, in data: Data) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        guard let regex = try? NSRegularExpression(pattern: "\(escaped)(?![A-Za-z0-9+_.-])") else { return false }
        let source = flat(data)
        return regex.firstMatch(in: source, range: NSRange(location: 0, length: (source as NSString).length)) != nil
    }

    /// Every top-level `N G obj … endobj` body, in file order, with
    /// whitespace collapsed.
    static func objects(in data: Data) -> [(number: Int, body: String)] {
        let source = flat(data)
        guard let regex = try? NSRegularExpression(
            pattern: "(\\d+) \\d+ obj(.*?)endobj", options: [.dotMatchesLineSeparators]
        ) else { return [] }
        let ns = source as NSString
        return regex.matches(in: source, range: NSRange(location: 0, length: ns.length)).map { match in
            (Int(ns.substring(with: match.range(at: 1))) ?? -1, ns.substring(with: match.range(at: 2)))
        }
    }

    /// Bodies of objects whose dictionary contains `marker` (e.g. "/Subtype /Highlight").
    static func objects(containing marker: String, in data: Data) -> [String] {
        objects(in: data).map(\.body).filter { $0.contains(marker) }
    }

    /// The top-level keys of the first dictionary in an object body,
    /// ignoring keys of nested dictionaries. Names alternate key/value; any
    /// non-name value (number, reference, string, array, dictionary) ends a
    /// value, so the next name is a key.
    static func topLevelKeys(of body: String) -> Set<String> {
        let chars = Array(body.unicodeScalars)
        var keys = Set<String>()
        var depth = 0
        var arrayDepth = 0
        var expectingKey = false
        var index = 0
        func valueEnded() { if depth == 1 && arrayDepth == 0 { expectingKey = true } }
        while index < chars.count {
            let c = chars[index]
            if c == "(" {
                var nesting = 1
                index += 1
                while index < chars.count && nesting > 0 {
                    if chars[index] == "\\" { index += 2; continue }
                    if chars[index] == "(" { nesting += 1 }
                    if chars[index] == ")" { nesting -= 1 }
                    index += 1
                }
                valueEnded(); continue
            }
            if c == "<" && index + 1 < chars.count && chars[index + 1] == "<" {
                depth += 1; index += 2
                if depth == 1 { expectingKey = true }
                continue
            }
            if c == ">" && index + 1 < chars.count && chars[index + 1] == ">" {
                depth -= 1; index += 2
                if depth == 0 { return keys }
                valueEnded(); continue
            }
            if c == "<" {
                while index < chars.count && chars[index] != ">" { index += 1 }
                index += 1; valueEnded(); continue
            }
            if c == "[" { arrayDepth += 1; index += 1; continue }
            if c == "]" { arrayDepth -= 1; index += 1; valueEnded(); continue }
            if c == "/" {
                var end = index + 1
                while end < chars.count && !" /<>[]()\n\r\t".unicodeScalars.contains(chars[end]) { end += 1 }
                if depth == 1 && arrayDepth == 0 {
                    var name = ""
                    name.unicodeScalars.append(contentsOf: chars[index..<end])
                    if expectingKey { keys.insert(name); expectingKey = false } else { expectingKey = true }
                }
                index = end; continue
            }
            if c == " " || c == "\n" || c == "\r" || c == "\t" { index += 1; continue }
            // Any other atom (number, R, true, null): a value at depth 1.
            while index < chars.count && !" /<>[]()\n\r\t".unicodeScalars.contains(chars[index]) { index += 1 }
            valueEnded()
        }
        return keys
    }
}

// MARK: - Large generated documents

/// Generated multi-page documents, built once per test run.
nonisolated enum BigPDF {
    static let needle = "lecternneedle"

    /// 600 pages, for the thumbnail spike.
    static let pages600: Data = make(pageCount: 600, needleEvery: 0)

    /// 2,400 pages with `needle` on every 50th page (first on page index 25), for the search spike.
    static let pages2400: Data = make(pageCount: 2400, needleEvery: 50)

    static func needlePages(pageCount: Int, every: Int) -> [Int] {
        guard every > 0 else { return [] }
        return (0..<pageCount).filter { $0 % every == every / 2 }
    }

    /// Text drawn with CoreText, so generation is thread-safe and the text is extractable.
    static func make(pageCount: Int, needleEvery: Int) -> Data {
        let data = NSMutableData()
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        let font = CTFontCreateWithName("Helvetica" as CFString, 11, nil)
        let filler = "The quick brown fox jumps over the lazy dog while the reader keeps its place in a long document."
        let needles = Set(needlePages(pageCount: pageCount, every: needleEvery))
        for index in 0..<pageCount {
            context.beginPDFPage(nil)
            var lines = ["Page \(index + 1)"]
            for row in 0..<30 { lines.append("\(row + 1). \(filler)") }
            if needles.contains(index) { lines.insert("Marker \(needle) on page \(index + 1)", at: 15) }
            var y: CGFloat = 740
            for line in lines {
                let attributed = NSAttributedString(string: line, attributes: [.init(kCTFontAttributeName as String): font])
                let ctLine = CTLineCreateWithAttributedString(attributed)
                context.textPosition = CGPoint(x: 54, y: y)
                CTLineDraw(ctLine, context)
                y -= 22
            }
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
}

/// Writes spike outputs into the test host's (sandbox container) temporary
/// directory, so they can be inspected by hand, e.g. with `qpdf --check`.
nonisolated enum SpikeArtifacts {
    static var directory: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("m0b-spikes", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    static func save(_ data: Data, as name: String) -> URL {
        let url = directory.appendingPathComponent(name)
        try? data.write(to: url)
        SpikeLog.note("artifact", url.path)
        return url
    }
}

// MARK: - Run loop and timing

enum Spin {
    /// Lets the main run loop process display, timers and queued work.
    static func runLoop(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}

nonisolated func monotonicSeconds() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
}

/// A lock-protected box for values written from arbitrary threads.
nonisolated final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
    var current: Value { withLock { $0 } }
}

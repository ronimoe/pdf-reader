import Foundation
@testable import PDFSave

/// Builds small PDFs byte by byte, so tests can produce exactly the structure (or damage) they need.
struct TestPDF {
    var out: [UInt8] = Array("%PDF-1.7\n".utf8)
    var offsets: [Int: Int] = [:]
    var generations: [Int: Int] = [:]
    /// Objects placed in an object stream: number → (stream number, index).
    var compressed: [Int: (Int, Int)] = [:]

    /// Catalog (1), page tree (2) and `count` pages (3, 4, …) with the given extra page entries.
    static func pages(_ count: Int, pageExtra: [Int: String] = [:]) -> TestPDF {
        var pdf = TestPDF()
        let kids = (0..<count).map { "\(3 + $0) 0 R" }.joined(separator: " ")
        pdf.obj(1, "<< /Type /Catalog /Pages 2 0 R >>")
        pdf.obj(2, "<< /Type /Pages /Kids [\(kids)] /Count \(count) >>")
        for i in 0..<count {
            pdf.obj(3 + i, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] \(pageExtra[i] ?? "")>>")
        }
        return pdf
    }

    mutating func obj(_ num: Int, _ body: String, gen: Int = 0) {
        offsets[num] = out.count
        generations[num] = gen
        out += Array("\(num) \(gen) obj\n\(body)\nendobj\n".utf8)
    }

    /// `dict` is the dictionary body without `<< >>`; `/Length` is added unless `length` overrides it.
    mutating func stream(_ num: Int, dict: String, data: [UInt8], length: String? = nil) {
        offsets[num] = out.count
        generations[num] = 0
        out += Array("\(num) 0 obj\n<< \(dict) /Length \(length ?? String(data.count)) >>\nstream\n".utf8)
        out += data
        out += Array("\nendstream\nendobj\n".utf8)
    }

    /// An uncompressed object stream. `headerOverride` replaces the "num offset" pairs.
    mutating func objStm(_ num: Int, _ members: [(Int, String)], headerOverride: String? = nil, length: String? = nil) {
        var body: [UInt8] = []
        var pairs: [String] = []
        for (i, (n, text)) in members.enumerated() {
            pairs.append("\(n) \(body.count)")
            body += Array((text + "\n").utf8)
            compressed[n] = (num, i)
        }
        let header = Array(((headerOverride ?? pairs.joined(separator: " ")) + "\n").utf8)
        stream(num, dict: "/Type /ObjStm /N \(members.count) /First \(header.count)", data: header + body, length: length)
    }

    static func runs(_ nums: [Int]) -> [[Int]] {
        var result: [[Int]] = []
        for n in nums.sorted() {
            if let last = result.last?.last, last + 1 == n { result[result.count - 1].append(n) } else { result.append([n]) }
        }
        return result
    }

    /// Classic table listing every uncompressed object, plus `extra` raw entries (e.g. free ones).
    func finishTable(trailer: String, extra: [Int: String] = [:], subsectionOverride: String? = nil) -> Data {
        var out = self.out
        let xref = out.count
        var entries: [Int: String] = [0: "0000000000 65535 f\r\n"]
        for (n, o) in offsets { entries[n] = String(format: "%010d %05d n\r\n", o, generations[n] ?? 0) }
        for (n, line) in extra { entries[n] = line }
        out += Array("xref\n".utf8)
        if let subsectionOverride {
            out += Array(subsectionOverride.utf8)
        } else {
            for run in Self.runs(Array(entries.keys)) {
                out += Array("\(run[0]) \(run.count)\n".utf8)
                for n in run { out += Array(entries[n]!.utf8) }
            }
        }
        out += Array("trailer\n<< \(trailer) >>\nstartxref\n\(xref)\n%%EOF\n".utf8)
        return Data(out)
    }

    /// Rows of a cross-reference stream (`/W [1 4 2]`) for everything added so far plus itself.
    func xrefRows(selfNumber: Int, selfOffset: Int, only: Set<Int>? = nil) -> (index: String, rows: [UInt8]) {
        var all: [Int: (UInt8, Int, Int)] = [0: (0, 0, 65535)]
        for (n, o) in offsets { all[n] = (1, o, generations[n] ?? 0) }
        for (n, (s, i)) in compressed { all[n] = (2, s, i) }
        all[selfNumber] = (1, selfOffset, 0)
        if let only { all = all.filter { only.contains($0.key) } }
        var rows: [UInt8] = []
        var index: [String] = []
        for run in Self.runs(Array(all.keys)) {
            index.append("\(run[0]) \(run.count)")
            for n in run {
                let (t, a, b) = all[n]!
                rows.append(t)
                rows += [UInt8((a >> 24) & 0xFF), UInt8((a >> 16) & 0xFF), UInt8((a >> 8) & 0xFF), UInt8(a & 0xFF)]
                rows += [UInt8((b >> 8) & 0xFF), UInt8(b & 0xFF)]
            }
        }
        return (index.joined(separator: " "), rows)
    }

    /// Ends the file with a cross-reference stream. `dict` replaces the generated dictionary body
    /// (use `{INDEX}` and `{SIZE}` placeholders), `data` replaces the encoded rows.
    func finishStream(number: Int, trailer: String, dict: String? = nil, data: [UInt8]? = nil, length: String? = nil) -> Data {
        var copy = self
        let offset = copy.out.count
        let (index, rows) = copy.xrefRows(selfNumber: number, selfOffset: offset)
        let size = max((offsets.keys.max() ?? 0), number) + 1
        let body = (dict ?? "/Type /XRef /W [1 4 2] /Index [{INDEX}] /Size {SIZE} \(trailer)")
            .replacingOccurrences(of: "{INDEX}", with: index).replacingOccurrences(of: "{SIZE}", with: String(size))
        copy.stream(number, dict: body, data: data ?? rows, length: length)
        copy.out += Array("startxref\n\(offset)\n%%EOF\n".utf8)
        return Data(copy.out)
    }

    /// zlib-wrapped DEFLATE, as PDF writers produce it.
    static func zlib(_ data: [UInt8]) -> [UInt8] {
        let raw = try! (Data(data) as NSData).compressed(using: .zlib) as Data
        return [0x78, 0x9C] + [UInt8](raw) + [0, 0, 0, 0]
    }
}

extension AnnotationChange {
    static let testNote = AnnotationChange.addNote(NewNote(pageIndex: 0, origin: PDFPoint(x: 10, y: 10), contents: "test"))
}

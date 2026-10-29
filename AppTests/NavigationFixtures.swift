import AppKit
import Persistence
@testable import Lectern

/// Builds PDFs from raw syntax with the features M2 reads: text on chosen
/// pages (or none, like a scan), an outline, page labels and an `/ID`.
enum FixturePDF {
    struct Entry {
        var title: String
        var page: Int
        /// The destination's top, in page space; nil for a `/Fit` destination.
        var top: Int? = 600
        var children: [Entry] = []
    }

    /// - Parameters:
    ///   - pageTexts: one page per element; nil means the page has no text.
    ///   - pageLabels: the inside of a `/PageLabels` number tree, such as
    ///     `/Nums [0 << /S /r >> 2 << /S /D >>]`.
    static func make(
        pageTexts: [String?],
        outline: [Entry] = [],
        pageLabels: String? = nil,
        id: String? = nil
    ) -> Data {
        var objects: [String] = []
        let pageCount = pageTexts.count
        let firstPage = 4
        let firstContent = firstPage + pageCount
        let firstOutline = firstContent + pageCount
        func pageRef(_ index: Int) -> String { "\(firstPage + index) 0 R" }

        var catalog = "<< /Type /Catalog /Pages 2 0 R"
        if !outline.isEmpty { catalog += " /Outlines \(firstOutline) 0 R" }
        if let pageLabels { catalog += " /PageLabels << \(pageLabels) >>" }
        catalog += " >>"
        objects.append(catalog)
        objects.append("<< /Type /Pages /Kids [\((0..<pageCount).map(pageRef).joined(separator: " "))] /Count \(pageCount) >>")
        objects.append("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
        for index in 0..<pageCount {
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents \(firstContent + index) 0 R >>")
        }
        for text in pageTexts {
            var stream = ""
            if let text {
                stream = "BT /F1 14 Tf 72 720 Td 18 TL\n"
                for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                    let escaped = line.replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "(", with: "\\(")
                        .replacingOccurrences(of: ")", with: "\\)")
                    stream += "(\(escaped)) Tj T*\n"
                }
                stream += "ET"
            }
            objects.append("<< /Length \(latin1(stream).count) >>\nstream\n\(stream)\nendstream")
        }

        if !outline.isEmpty {
            // Number every entry depth-first after the outline root.
            var numbered: [(number: Int, body: String)] = []
            var next = firstOutline + 1
            func layout(_ entries: [Entry], parent: Int) -> [Int] {
                let numbers = entries.map { _ in
                    defer { next += 1 }
                    return next
                }
                for (offset, entry) in entries.enumerated() {
                    let children = layout(entry.children, parent: numbers[offset])
                    var body = "<< /Title (\(entry.title)) /Parent \(parent) 0 R"
                    if offset > 0 { body += " /Prev \(numbers[offset - 1]) 0 R" }
                    if offset < entries.count - 1 { body += " /Next \(numbers[offset + 1]) 0 R" }
                    if let first = children.first, let last = children.last {
                        body += " /First \(first) 0 R /Last \(last) 0 R /Count \(children.count)"
                    }
                    let destination = entry.top.map { "/XYZ 0 \($0) null" } ?? "/Fit"
                    body += " /Dest [\(pageRef(entry.page)) \(destination)] >>"
                    numbered.append((numbers[offset], body))
                }
                return numbers
            }
            let top = layout(outline, parent: firstOutline)
            objects.append("<< /Type /Outlines /First \(top.first!) 0 R /Last \(top.last!) 0 R /Count \(top.count) >>")
            objects += numbered.sorted { $0.number < $1.number }.map(\.body)
        }

        var output = "%PDF-1.7\n"
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(latin1(output).count)
            output += "\(index + 1) 0 obj\n\(body)\nendobj\n"
        }
        let xrefOffset = latin1(output).count
        output += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets {
            output += String(format: "%010d 00000 n \n", offset)
        }
        let identifier = id.map { " /ID [<\($0)> <\($0)>]" } ?? ""
        output += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R\(identifier) >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
        return latin1(output)
    }

    /// Content streams use WinAnsi, so the file is written as Latin-1 and
    /// accented test words come out as single bytes.
    private static func latin1(_ string: String) -> Data {
        string.data(using: .isoLatin1) ?? Data(string.utf8)
    }

    /// `count` pages of plain prose, each line naming its page.
    static func prose(pages count: Int, id: String? = nil) -> Data {
        make(pageTexts: (0..<count).map { index in
            (0..<30).map { line in "Page \(index + 1) line \(line) of ordinary prose about reading" }.joined(separator: "\n")
        }, id: id)
    }

    /// A book: roman front matter, an outline with a nested entry, text.
    static func book() -> Data {
        make(
            pageTexts: (0..<8).map { "Book page \($0 + 1)\nchapter text with a needle and a haystack" },
            outline: [
                Entry(title: "Preface", page: 0),
                Entry(title: "Chapter One", page: 2, children: [Entry(title: "Section 1.1", page: 3, top: 400)]),
                Entry(title: "Chapter Two", page: 6, top: nil),
            ],
            pageLabels: "/Nums [0 << /S /r >> 2 << /S /D >>]"
        )
    }
}

/// A temporary folder for files a test opens as real documents. State
/// stored for them lands in a store inside the folder, never the app's
/// container.
final class TemporaryFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "LecternAppTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func write(_ data: Data, to name: String) throws -> URL {
        let file = url.appending(path: name)
        try data.write(to: file)
        return file
    }

    func store(debounce: Duration = .seconds(60)) -> DocumentStateStore {
        DocumentStateStore(directory: url.appending(path: "Store", directoryHint: .isDirectory), debounce: debounce)
    }
}

extension ReaderDocument {
    /// Opens `url` the way NSDocumentController does, without displaying it.
    static func opened(_ url: URL) throws -> ReaderDocument {
        try ReaderDocument(contentsOf: url, ofType: "com.adobe.pdf")
    }
}

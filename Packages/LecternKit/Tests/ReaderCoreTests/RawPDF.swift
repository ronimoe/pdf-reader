import Foundation

/// Writes minimal, valid PDFs from raw syntax, for catalog and trailer keys
/// that CoreGraphics can't produce.
enum RawPDF {
    /// - Parameters:
    ///   - catalogExtras: entries appended inside the catalog dictionary.
    ///   - trailerExtras: entries appended inside the trailer dictionary.
    ///   - pageRotations: one page per entry, with that `/Rotate`.
    static func make(catalogExtras: String = "", trailerExtras: String = "", pageRotations: [Int] = [0]) -> Data {
        var objects: [String] = []
        let firstPage = 3
        let kids = pageRotations.indices.map { "\(firstPage + $0) 0 R" }.joined(separator: " ")
        objects.append("<< /Type /Catalog /Pages 2 0 R \(catalogExtras) >>")
        objects.append("<< /Type /Pages /Kids [\(kids)] /Count \(pageRotations.count) >>")
        for rotation in pageRotations {
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Rotate \(rotation) >>")
        }

        var output = "%PDF-1.7\n"
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(output.utf8.count)
            output += "\(index + 1) 0 obj\n\(body)\nendobj\n"
        }
        let xrefOffset = output.utf8.count
        output += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets {
            output += String(format: "%010d 00000 n \n", offset)
        }
        output += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R \(trailerExtras) >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
        return Data(output.utf8)
    }
}

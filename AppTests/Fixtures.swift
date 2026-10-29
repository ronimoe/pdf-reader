import AppKit
import PDFKit
import ReaderUI
@testable import Lectern

/// Builds small PDFs in memory for tests.
enum TestPDF {
    static func make(pageCount: Int) -> Data? {
        make(pageCount: pageCount, auxiliaryInfo: nil)
    }

    /// An encrypted PDF. With `user` nil it opens without a password but the
    /// permission flags still apply until the owner password is given.
    static func encrypted(
        user: String?,
        owner: String,
        allowsCopying: Bool = false,
        allowsPrinting: Bool = false,
        pageCount: Int = 2
    ) -> Data? {
        var info: [CFString: Any] = [
            kCGPDFContextOwnerPassword: owner,
            kCGPDFContextAllowsCopying: allowsCopying,
            kCGPDFContextAllowsPrinting: allowsPrinting,
            kCGPDFContextEncryptionKeyLength: 128,
        ]
        if let user { info[kCGPDFContextUserPassword] = user }
        return make(pageCount: pageCount, auxiliaryInfo: info as CFDictionary)
    }

    private static func make(pageCount: Int, auxiliaryInfo: CFDictionary?) -> Data? {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &box, auxiliaryInfo) else { return nil }
        for index in 0..<pageCount {
            context.beginPDFPage(nil)
            let text = "Page \(index + 1)" as NSString
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            text.draw(at: CGPoint(x: 72, y: 700), withAttributes: [.font: NSFont.systemFont(ofSize: 24)])
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
}

/// Writes minimal, valid PDFs from raw syntax, for catalog keys and page
/// rotations that CoreGraphics can't produce.
enum RawPDF {
    static func make(catalogExtras: String = "", pageRotations: [Int] = [0, 0, 0]) -> Data {
        var objects: [String] = []
        let kids = pageRotations.indices.map { "\(3 + $0) 0 R" }.joined(separator: " ")
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
        output += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
        return Data(output.utf8)
    }
}

/// Records what a window controller asked to show, instead of showing it.
final class RecordingPresenter: ReaderPresenting {
    private(set) var prompts: [PasswordPromptModel] = []
    private(set) var dismissals = 0
    private(set) var explained: [BlockedAction] = []
    private(set) var enterOwnerPassword: (() -> Void)?

    func showPasswordPrompt(_ model: PasswordPromptModel, on window: NSWindow) {
        prompts.append(model)
    }

    func dismissPasswordPrompt(on window: NSWindow) {
        dismissals += 1
    }

    func explain(_ action: BlockedAction, on window: NSWindow, enterOwnerPassword: @escaping () -> Void) {
        explained.append(action)
        self.enterOwnerPassword = enterOwnerPassword
    }
}

extension ReaderDocument {
    static func loaded(_ data: Data) throws -> ReaderDocument {
        let document = ReaderDocument()
        try document.read(from: data, ofType: "com.adobe.pdf")
        document.fileType = "com.adobe.pdf"
        return document
    }
}

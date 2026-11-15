import CoreGraphics
import Foundation

/// Whether a document looks like a slide deck, so that opening one can suggest View ▸ Start
/// Presentation, once. Only ever a suggestion: a presentation never starts by itself.
///
/// A deck is a document that asks to open full screen (`/PageMode /FullScreen`), one whose
/// creator is presentation software and whose first page is landscape, or three or more pages
/// of one landscape size between 5:4 and a little past 16:9. A landscape report printed on A4
/// passes too; all it costs is one brief notice.
public enum SlideDeckHints {
    /// Lowercased names that presentation software writes into `/Creator` or `/Producer`
    /// ("LaTeX with Beamer class", "Microsoft PowerPoint", "Keynote", "Impress").
    static let presentationSoftware = ["beamer", "powerpoint", "keynote", "impress", "google slides"]

    /// The shapes slides come in, width over height: 5:4 to a little past 16:9 (1.78).
    static let slideRatios: ClosedRange<CGFloat> = 1.24...1.86

    /// - Parameters:
    ///   - pageSizes: each page's size as it appears, its own `/Rotate` applied.
    ///   - opensInFullScreen: the catalog's `/PageMode` is `/FullScreen`.
    ///   - creator: the info dictionary's `/Creator` and `/Producer`, in any form.
    public static func looksLikeSlides(pageSizes: [CGSize], opensInFullScreen: Bool, creator: String?) -> Bool {
        guard let first = pageSizes.first, first.width > 0, first.height > 0 else { return false }
        if opensInFullScreen { return true }
        if let creator, first.width > first.height {
            let name = creator.lowercased()
            if presentationSoftware.contains(where: name.contains) { return true }
        }
        guard pageSizes.count >= 3, slideRatios.contains(first.width / first.height) else { return false }
        return pageSizes.allSatisfy { abs($0.width - first.width) < 1 && abs($0.height - first.height) < 1 }
    }

    /// Reads the hints from an unlocked document's catalog, info dictionary and first `limit`
    /// pages, through CoreGraphics so that no `PDFPage` is created. A locked document yields
    /// false.
    public static func looksLikeSlides(_ document: CGPDFDocument, limit: Int = 200) -> Bool {
        guard document.isUnlocked, document.numberOfPages > 0 else { return false }
        let sizes: [CGSize] = (1...min(document.numberOfPages, limit)).compactMap { number in
            guard let page = document.page(at: number) else { return nil }
            return SlideLayout.turnedSize(of: page.getBoxRect(.cropBox).size, rotation: Int(page.rotationAngle))
        }
        var opensInFullScreen = false
        if let catalog = document.catalog {
            var mode: UnsafePointer<CChar>?
            if CGPDFDictionaryGetName(catalog, "PageMode", &mode), let mode {
                opensInFullScreen = String(cString: mode) == "FullScreen"
            }
        }
        var creator = ""
        if let info = document.info {
            for key in ["Creator", "Producer"] {
                var value: CGPDFStringRef?
                if CGPDFDictionaryGetString(info, key, &value), let value, let text = CGPDFStringCopyTextString(value) {
                    creator += " " + (text as String)
                }
            }
        }
        return looksLikeSlides(pageSizes: sizes, opensInFullScreen: opensInFullScreen, creator: creator)
    }
}

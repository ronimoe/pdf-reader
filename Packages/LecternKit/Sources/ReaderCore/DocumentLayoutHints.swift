import CoreGraphics

/// The layout a PDF asks for in its catalog. These are the defaults for the
/// cover-page and right-to-left settings; the user can override both per
/// document (B1).
public struct DocumentLayoutHints: Hashable, Sendable {
    /// `/PageLayout /TwoPageRight` or `/TwoColumnRight`: odd pages on the
    /// right, so the first page stands alone.
    public var coverPageAlone: Bool
    /// `/ViewerPreferences << /Direction /R2L >>`.
    public var rightToLeft: Bool

    public static let none = DocumentLayoutHints(coverPageAlone: false, rightToLeft: false)

    public init(coverPageAlone: Bool, rightToLeft: Bool) {
        self.coverPageAlone = coverPageAlone
        self.rightToLeft = rightToLeft
    }

    /// Reads the hints from an unlocked document's catalog. A locked document
    /// has no readable catalog and yields `.none`.
    public init(document: CGPDFDocument) {
        guard document.isUnlocked, let catalog = document.catalog else {
            self = .none
            return
        }
        self.init(catalog: catalog)
    }

    public init(catalog: CGPDFDictionaryRef) {
        let layout = Self.name(for: "PageLayout", in: catalog)
        coverPageAlone = layout == "TwoPageRight" || layout == "TwoColumnRight"

        var preferences: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(catalog, "ViewerPreferences", &preferences), let preferences {
            rightToLeft = Self.name(for: "Direction", in: preferences) == "R2L"
        } else {
            rightToLeft = false
        }
    }

    private static func name(for key: String, in dictionary: CGPDFDictionaryRef) -> String? {
        var value: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, key, &value), let value else { return nil }
        return String(cString: value)
    }
}

import CoreGraphics
import Foundation
import PDFKit
import ReaderCore

/// Draws page thumbnails off the main thread (architecture §4.6).
///
/// The actor opens its own `PDFDocument` from the same bytes as the one on
/// screen, the first time it draws, so neither opening the window nor the
/// main thread's model pays for it. PDFKit objects aren't safe to share
/// between threads, but separate documents render in parallel (measured on
/// macOS 26: 100 thumbnails in 70 ms on a background thread while the main
/// thread drew from its own document).
///
/// Results are cached in memory, keyed by page, size and rotation.
public actor PageRenderer {
    private let data: Data
    private let password: String?
    private var loaded = false
    private var document: PDFDocument?
    /// Each page's own `/Rotate`, recorded the first time the page is drawn.
    private var originalRotations: [Int: Int] = [:]
    private var cache: [CacheKey: CGImage] = [:]
    private var cacheOrder: [CacheKey] = []
    private let cacheLimit: Int

    /// Thumbnails drawn (not served from the cache), and how many of those
    /// were drawn on the main thread, which should be none.
    public private(set) var renderCount = 0
    public private(set) var mainThreadRenderCount = 0

    nonisolated struct CacheKey: Hashable, Sendable {
        var pageIndex: Int
        var width: Int
        var height: Int
        var rotation: Int
    }

    /// - Parameters:
    ///   - data: the document's bytes.
    ///   - password: the password that opened it, for encrypted documents.
    public init(data: Data, password: String? = nil, cacheLimit: Int = 400) {
        self.data = data
        self.password = password
        self.cacheLimit = cacheLimit
    }

    private func loadedDocument() -> PDFDocument? {
        if !loaded {
            loaded = true
            document = PDFDocument.opened(data: data, password: password)
        }
        return document
    }

    public var pageCount: Int { loadedDocument()?.pageCount ?? 0 }

    /// The page drawn to fit `size` points at `scale` pixels per point, with
    /// the view rotation (B9) on top of the page's own. Nil for a page that
    /// doesn't exist, a locked document, or a cancelled request.
    public func thumbnail(pageIndex: Int, fitting size: CGSize, scale: CGFloat, rotation: Int) -> CGImage? {
        let pixelWidth = Int((size.width * scale).rounded())
        let pixelHeight = Int((size.height * scale).rounded())
        let key = CacheKey(pageIndex: pageIndex, width: pixelWidth, height: pixelHeight, rotation: ViewSettings.normalized(rotation))
        if let cached = cache[key] { return cached }
        // Requests for rows that scrolled away are cancelled before they run.
        guard !Task.isCancelled, let document = loadedDocument(), !document.isLocked,
              pageIndex >= 0, pageIndex < document.pageCount, let page = document.page(at: pageIndex),
              pixelWidth > 0, pixelHeight > 0
        else { return nil }
        renderCount += 1
        if pthread_main_np() != 0 { mainThreadRenderCount += 1 }
        let original = originalRotations[pageIndex] ?? page.rotation
        originalRotations[pageIndex] = original
        page.rotation = ViewSettings.normalized(original + rotation)
        let image = page.thumbnail(of: CGSize(width: pixelWidth, height: pixelHeight), for: .cropBox)
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        store(cgImage, for: key)
        return cgImage
    }

    private func store(_ image: CGImage, for key: CacheKey) {
        cache[key] = image
        cacheOrder.append(key)
        if cacheOrder.count > cacheLimit {
            let evicted = cacheOrder.removeFirst()
            cache[evicted] = nil
        }
    }

    var cachedCount: Int { cache.count }
}

/// Finds pages without a text layer, off the main thread, from its own copy
/// of the document, opened when first asked. Searching uses it to tell "no
/// results" from "nothing to search" (B8).
public actor TextInventory {
    private let data: Data
    private let password: String?
    private var result: [Int]?

    public init(data: Data, password: String? = nil) {
        self.data = data
        self.password = password
    }

    /// The indexes of pages with no extractable text.
    public func pagesWithoutText() -> [Int] {
        if let result { return result }
        guard let document = PDFDocument.opened(data: data, password: password), !document.isLocked else { return [] }
        var missing: [Int] = []
        for index in 0..<document.pageCount {
            if Task.isCancelled { return missing }
            let text = document.page(at: index)?.string ?? ""
            if text.allSatisfy(\.isWhitespace) { missing.append(index) }
        }
        result = missing
        return missing
    }
}

private extension PDFDocument {
    nonisolated static func opened(data: Data, password: String?) -> PDFDocument? {
        let document = PDFDocument(data: data)
        if let password, document?.isLocked == true {
            document?.unlock(withPassword: password)
        }
        return document
    }
}

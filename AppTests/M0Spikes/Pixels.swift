import AppKit
import CoreGraphics
import PDFKit

/// Counts pixel classes in an image, for offscreen visual checks.
nonisolated struct PixelStats: CustomStringConvertible {
    var total = 0
    var dark = 0      // text: all channels < 100
    var yellow = 0    // highlight: R,G high, B low
    var nonWhite = 0  // anything not near-white
    var red = 0       // square annotation fill: R high, G,B low

    var description: String { "total=\(total) dark=\(dark) yellow=\(yellow) red=\(red) nonWhite=\(nonWhite)" }

    /// Draws `image` into a known RGBA buffer, then classifies each pixel.
    static func of(_ image: CGImage) -> PixelStats {
        let width = image.width, height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        buffer.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var stats = PixelStats()
        stats.total = width * height
        for index in stride(from: 0, to: buffer.count, by: 4) {
            let r = Int(buffer[index]), g = Int(buffer[index + 1]), b = Int(buffer[index + 2])
            if r < 100 && g < 100 && b < 100 { stats.dark += 1 }
            if r > 200 && g > 180 && b < 140 { stats.yellow += 1 }
            if r < 235 || g < 235 || b < 235 { stats.nonWhite += 1 }
            if r > 200 && g < 80 && b < 80 { stats.red += 1 }
        }
        return stats
    }

    /// Renders a page with `PDFPage.draw(with:to:)` into a white bitmap.
    static func render(_ page: PDFPage, scale: CGFloat = 1) -> CGImage {
        let bounds = page.bounds(for: .mediaBox)
        let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()!
    }
}

extension NSView {
    /// `cacheDisplay(in:to:)` of the whole view, as a CGImage.
    func cachedDisplayImage() -> CGImage? {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        return rep.cgImage
    }

    /// `CALayer.render(in:)` of the view's layer tree, as a CGImage.
    func layerRenderedImage() -> CGImage? {
        guard let layer, bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = window?.backingScaleFactor ?? 2
        let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        return context.makeImage()
    }
}

extension NSImage {
    var cgImageValue: CGImage? {
        var rect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}

/// Adds a yellow highlight over the first text line of a TestPDF page.
func addHighlight(to page: PDFPage) -> PDFAnnotation {
    let bounds = CGRect(x: 60, y: 690, width: 300, height: 40)
    let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
    annotation.color = NSColor(srgbRed: 1, green: 0.9, blue: 0, alpha: 1)
    annotation.quadrilateralPoints = [
        NSValue(point: CGPoint(x: 0, y: 40)), NSValue(point: CGPoint(x: 300, y: 40)),
        NSValue(point: CGPoint(x: 0, y: 0)), NSValue(point: CGPoint(x: 300, y: 0)),
    ]
    page.addAnnotation(annotation)
    return annotation
}

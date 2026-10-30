// Draws the DMG window's background from layout.json: a caption, an arrow from Lectern to
// Applications, and a note pointing at "Read Me First.txt". Writes background.png and
// background@2x.png, which dmgbuild combines into one HiDPI TIFF. Draws offscreen only.
//
// The background is one flat mid-tone, because Finder draws the icon labels itself: black in
// light mode, white in dark mode. The colour is chosen so both reach 4.5:1, and this script
// refuses to draw if it doesn't.
//
// Usage: swift packaging/dmg/make-background.swift <layout.json> <output folder>
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Layout: Decodable {
    struct Size: Decodable { let width: Double; let height: Double }
    struct Text: Decodable { let text: String; let y: Double; let size: Double }
    struct Item: Decodable { let name: String; let x: Double; let y: Double }
    struct Arrow: Decodable { let fromX: Double; let toX: Double; let y: Double }
    let image: Size
    let caption: Text
    let arrow: Arrow
    let separatorY: Double
    let note: Text
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-background: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else { fail("usage: make-background.swift <layout.json> <output folder>") }
let layout: Layout
do {
    layout = try JSONDecoder().decode(Layout.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
} catch {
    fail("can't read \(arguments[1]): \(error)")
}
let outputFolder = URL(fileURLWithPath: arguments[2], isDirectory: true)

// #70777F
let base = (red: 0x70, green: 0x77, blue: 0x7F)

func linear(_ channel: Int) -> Double {
    let c = Double(channel) / 255
    return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
}
let luminance = 0.2126 * linear(base.red) + 0.7152 * linear(base.green) + 0.0722 * linear(base.blue)
let againstWhite = 1.05 / (luminance + 0.05)
let againstBlack = (luminance + 0.05) / 0.05
guard againstWhite >= 4.5, againstBlack >= 4.5 else {
    fail(String(format: "the background gives labels %.2f:1 (white) and %.2f:1 (black); both must be at least 4.5", againstWhite, againstBlack))
}

let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

func drawText(_ text: String, size: Double, emphasized: Bool, centreY: Double, in context: CGContext) {
    let font = CTFontCreateUIFontForLanguage(emphasized ? .emphasizedSystem : .system, size, nil)!
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): white,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
    guard bounds.width <= layout.image.width - 40 else { fail("\"\(text)\" is too wide for the window") }
    context.saveGState()
    // The context is flipped to put the origin at the top left; text has to be drawn unflipped.
    context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
    context.textPosition = CGPoint(x: (layout.image.width - bounds.width) / 2 - bounds.minX,
                                   y: centreY + (ascent - descent) / 2)
    CTLineDraw(line, context)
    context.restoreGState()
}

func render(scale: Int) -> CGImage {
    let width = Int(layout.image.width) * scale, height = Int(layout.image.height) * scale
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fail("can't make a \(width)×\(height) bitmap")
    }
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))

    context.setFillColor(CGColor(srgbRed: CGFloat(base.red) / 255, green: CGFloat(base.green) / 255,
                                 blue: CGFloat(base.blue) / 255, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: layout.image.width, height: layout.image.height))

    drawText(layout.caption.text, size: layout.caption.size, emphasized: true, centreY: layout.caption.y, in: context)

    // The arrow: a rounded shaft and a solid head, pointing at Applications.
    let arrow = layout.arrow
    let headLength = 24.0, headHalfWidth = 15.0, shaft = 7.0
    context.setFillColor(white.copy(alpha: 0.9)!)
    context.setStrokeColor(white.copy(alpha: 0.9)!)
    context.setLineWidth(shaft)
    context.setLineCap(.round)
    context.move(to: CGPoint(x: arrow.fromX, y: arrow.y))
    context.addLine(to: CGPoint(x: arrow.toX - headLength + 2, y: arrow.y))
    context.strokePath()
    context.setLineJoin(.round)
    context.setLineWidth(3)
    context.move(to: CGPoint(x: arrow.toX, y: arrow.y))
    context.addLine(to: CGPoint(x: arrow.toX - headLength, y: arrow.y - headHalfWidth))
    context.addLine(to: CGPoint(x: arrow.toX - headLength, y: arrow.y + headHalfWidth))
    context.closePath()
    context.drawPath(using: .fillStroke)

    context.setStrokeColor(white.copy(alpha: 0.3)!)
    context.setLineWidth(1)
    context.setLineCap(.butt)
    context.move(to: CGPoint(x: 40, y: layout.separatorY))
    context.addLine(to: CGPoint(x: layout.image.width - 40, y: layout.separatorY))
    context.strokePath()

    drawText(layout.note.text, size: layout.note.size, emphasized: false, centreY: layout.note.y, in: context)

    guard let image = context.makeImage() else { fail("can't render the background") }
    return image
}

func write(_ image: CGImage, dpi: Int, to name: String) {
    let url = outputFolder.appendingPathComponent(name)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("can't write \(url.path)")
    }
    let properties = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary
    CGImageDestinationAddImage(destination, image, properties)
    guard CGImageDestinationFinalize(destination) else { fail("can't write \(url.path)") }
}

try? FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
write(render(scale: 1), dpi: 72, to: "background.png")
write(render(scale: 2), dpi: 144, to: "background@2x.png")
print(String(format: "background: %.0f×%.0f pt; white labels %.2f:1, black labels %.2f:1", layout.image.width,
             layout.image.height, againstWhite, againstBlack))

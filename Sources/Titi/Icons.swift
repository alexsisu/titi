import AppKit
import ImageIO
import UniformTypeIdentifiers

/// titi's icons, design 1c "You are here": a map marker seen from above. A ring with a dot in the middle, cream on a
/// green tile for the app; a single-colour template glyph for the menu bar, so macOS tints it for light and dark.
enum TitiIcon {
    static let green = CGColor(srgbRed: 0x2f / 255, green: 0x5d / 255, blue: 0x50 / 255, alpha: 1)
    static let cream = CGColor(srgbRed: 0xf3 / 255, green: 0xf1 / 255, blue: 0xec / 255, alpha: 1)

    /// The menu-bar glyph, drawn once: the status item asks for it on every change.
    static let menuBarGlyph = menuBar()

    /// The menu-bar glyph: 18 pt, a ring (r 6, 1.6 pt line) around a dot (r 2.2).
    static func menuBar() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()
            let ring = NSBezierPath(ovalIn: NSRect(x: 3, y: 3, width: 12, height: 12))
            ring.lineWidth = 1.6
            ring.stroke()
            NSBezierPath(ovalIn: NSRect(x: 9 - 2.2, y: 9 - 2.2, width: 4.4, height: 4.4)).fill()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "titi"
        return img
    }

    /// Ring and dot on the 1024 grid, thicker at small sizes so they stay legible (the design's 16, 32 and 64 px cuts).
    static func strokes(points: Int) -> (ring: CGFloat, dot: CGFloat) {
        switch points {
        case ...16: return (88, 116)
        case ...32: return (72, 104)
        case ...128: return (64, 96)
        default: return (60, 92)
        }
    }

    /// The app icon at `pixels` square, drawn for a slot shown at `points`: the green tile (824 of 1024, radius 185,
    /// the macOS icon grid) with the cream ring and dot.
    static func appIcon(pixels: Int, points: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let s = CGFloat(pixels) / 1024
        ctx.scaleBy(x: s, y: s)
        let (ring, dot) = strokes(points: points)
        ctx.setFillColor(green)
        ctx.addPath(CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185,
                           cornerHeight: 185, transform: nil))
        ctx.fillPath()
        ctx.setStrokeColor(cream)
        ctx.setLineWidth(ring)
        ctx.strokeEllipse(in: CGRect(x: 512 - 236, y: 512 - 236, width: 472, height: 472))
        ctx.setFillColor(cream)
        ctx.fillEllipse(in: CGRect(x: 512 - dot, y: 512 - dot, width: dot * 2, height: dot * 2))
        return ctx.makeImage()
    }

    /// `Titi --make-iconset <dir>`: the PNGs `iconutil -c icns` turns into AppIcon.icns (scripts/package.sh).
    static func writeIconset(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = "icon_\(points)x\(points)" + (scale == 2 ? "@2x" : "") + ".png"
                guard let img = appIcon(pixels: points * scale, points: points),
                      let dest = CGImageDestinationCreateWithURL(dir.appendingPathComponent(name) as CFURL,
                                                                 UTType.png.identifier as CFString, 1, nil)
                else { throw NSError(domain: "titi.icon", code: 1) }
                CGImageDestinationAddImage(dest, img, nil)
                guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "titi.icon", code: 2) }
            }
        }
    }
}

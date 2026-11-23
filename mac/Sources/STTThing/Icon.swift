import AppKit

/// The app's icon and menu bar glyph, drawn in code: two subtitle lines, the
/// lower one green like the mark of the phrase being spoken. (SF Symbols
/// may not be used in app icons, so nothing here comes from them.)
enum AppIcon {
    private static let green = NSColor(red: 0.373, green: 0.827, blue: 0.553, alpha: 1)

    /// The app icon at `size` points, on the standard macOS icon grid: a
    /// rounded square inset by 10% of the canvas.
    static func image(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let s = rect.width
            let body = rect.insetBy(dx: s * 0.1, dy: s * 0.1)
            let radius = body.width * 0.225
            let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = s * 0.02
            shadow.shadowOffset = NSSize(width: 0, height: -s * 0.008)
            shadow.set()
            NSColor(red: 0.09, green: 0.09, blue: 0.10, alpha: 1).setFill()
            shape.fill()
            NSGraphicsContext.restoreGraphicsState()

            NSGradient(colors: [
                NSColor(red: 0.20, green: 0.20, blue: 0.22, alpha: 1),
                NSColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1),
            ])?.draw(in: shape, angle: -90)

            // Two subtitle lines in the lower half, left aligned like captions.
            let w = body.width
            let barHeight = w * 0.085
            let left = body.minX + w * 0.2
            let top = NSRect(x: left, y: body.minY + w * 0.36, width: w * 0.6, height: barHeight)
            let bottom = NSRect(x: left, y: body.minY + w * 0.2, width: w * 0.38, height: barHeight)
            NSColor.white.withAlphaComponent(0.92).setFill()
            NSBezierPath(roundedRect: top, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
            green.setFill()
            NSBezierPath(roundedRect: bottom, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()

            // A faint frame line across the top: the panel's top bar.
            let topBar = NSRect(x: left, y: body.minY + w * 0.66, width: w * 0.6, height: w * 0.03)
            NSColor.white.withAlphaComponent(0.22).setFill()
            NSBezierPath(roundedRect: topBar, xRadius: topBar.height / 2, yRadius: topBar.height / 2).fill()
            return true
        }
    }

    /// Menu bar glyph: a caption box with two lines. A template image, so
    /// macOS colors it for the light or dark menu bar.
    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()
            let box = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 3.5, width: 15, height: 11), xRadius: 3, yRadius: 3)
            box.lineWidth = 1.4
            box.stroke()
            NSBezierPath(roundedRect: NSRect(x: 4, y: 9, width: 10, height: 2), xRadius: 1, yRadius: 1).fill()
            NSBezierPath(roundedRect: NSRect(x: 4, y: 6, width: 6, height: 2), xRadius: 1, yRadius: 1).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Writes an .iconset folder for `iconutil -c icns` (make-app.sh runs the
    /// binary with --render-iconset <dir>).
    static func writeIconset(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = base * scale
                guard let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                    bytesPerRow: 0, bitsPerPixel: 0
                ) else { continue }
                rep.size = NSSize(width: pixels, height: pixels)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                image(size: CGFloat(pixels)).draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
                NSGraphicsContext.restoreGraphicsState()
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                try rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
            }
        }
    }
}

import AppKit
import SwiftUI

/// ChatGauge's mark: the Gauge family's open ring with a small speech bubble inside.
enum ChatMarkGeometry {
    static let lineWidthRatio: CGFloat = 0.105

    /// Ring + bubble outline, y-down (SwiftUI / flipped NSImage).
    static func strokePath(in rect: CGRect) -> CGPath {
        let s = min(rect.width, rect.height)
        let ox = rect.midX - s / 2, oy = rect.midY - s / 2
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
        let path = CGMutablePath()
        // Ring: 300° arc with the gap on the upper right, like the rest of the family.
        let r: CGFloat = 0.36
        var first = true
        for deg in stride(from: -15.0, through: 285.0, by: 2.5) {
            let a = deg * .pi / 180
            let pt = p(0.5 + r * CGFloat(cos(a)), 0.5 + r * CGFloat(sin(a)))
            if first { path.move(to: pt); first = false } else { path.addLine(to: pt) }
        }
        // Speech bubble.
        path.addRoundedRect(in: CGRect(x: ox + 0.31 * s, y: oy + 0.35 * s, width: 0.38 * s, height: 0.25 * s),
                            cornerWidth: 0.07 * s, cornerHeight: 0.07 * s)
        return path
    }

    /// The bubble's tail (filled).
    static func tailPath(in rect: CGRect) -> CGPath {
        let s = min(rect.width, rect.height)
        let ox = rect.midX - s / 2, oy = rect.midY - s / 2
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
        let path = CGMutablePath()
        path.move(to: p(0.39, 0.59))
        path.addLine(to: p(0.37, 0.70))
        path.addLine(to: p(0.50, 0.59))
        path.closeSubpath()
        return path
    }
}

struct ChatMarkView: View {
    var size: CGFloat = 18
    var body: some View {
        ZStack {
            Path(ChatMarkGeometry.strokePath(in: CGRect(x: 0, y: 0, width: size, height: size)))
                .stroke(style: StrokeStyle(lineWidth: size * ChatMarkGeometry.lineWidthRatio, lineCap: .round, lineJoin: .round))
            Path(ChatMarkGeometry.tailPath(in: CGRect(x: 0, y: 0, width: size, height: size)))
                .fill()
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

enum ChatMarkImage {
    /// Template image for the menu bar: adapts to light, dark and tinted menu bars.
    static func template(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let inset = rect.insetBy(dx: size * 0.03, dy: size * 0.03)
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.addPath(ChatMarkGeometry.strokePath(in: inset))
            ctx.setLineWidth(size * ChatMarkGeometry.lineWidthRatio * 1.15)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.strokePath()
            ctx.addPath(ChatMarkGeometry.tailPath(in: inset))
            ctx.fillPath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "ChatGauge"
        return image
    }

    /// The template image with a small status dot in the lower-right corner (not a template, so the dot keeps its color).
    static func withDot(size: CGFloat = 18, color: NSColor, appearance: NSAppearance?) -> NSImage {
        let base = template(size: size)
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            var ink = NSColor.labelColor
            (appearance ?? NSApp.effectiveAppearance).performAsCurrentDrawingAppearance {
                ink = NSColor.labelColor.usingColorSpace(.sRGB) ?? .black
            }
            let tinted = NSImage(size: rect.size, flipped: false) { r in
                base.draw(in: r)
                ink.set()
                r.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: rect)
            let d = size * 0.34
            let dot = NSRect(x: rect.maxX - d, y: rect.minY, width: d, height: d)
            NSColor.clear.set()
            color.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "ChatGauge"
        return image
    }

    /// App icon artwork (for the generated .icns): the mark on a rounded tile.
    static func iconArtwork(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let tile = rect.insetBy(dx: size * 0.1, dy: size * 0.1)
            let bg = CGPath(roundedRect: tile, cornerWidth: size * 0.2, cornerHeight: size * 0.2, transform: nil)
            ctx.addPath(bg)
            ctx.clip()
            let colors = [NSColor(srgbRed: 0.13, green: 0.16, blue: 0.22, alpha: 1).cgColor,
                          NSColor(srgbRed: 0.05, green: 0.06, blue: 0.09, alpha: 1).cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
                ctx.drawLinearGradient(g, start: CGPoint(x: tile.midX, y: tile.minY), end: CGPoint(x: tile.midX, y: tile.maxY), options: [])
            }
            ctx.resetClip()
            let art = tile.insetBy(dx: tile.width * 0.12, dy: tile.height * 0.12)
            ctx.setStrokeColor(NSColor(srgbRed: 0.36, green: 0.85, blue: 0.55, alpha: 1).cgColor)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.addPath(ChatMarkGeometry.strokePath(in: art))
            ctx.setLineWidth(art.width * ChatMarkGeometry.lineWidthRatio)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.strokePath()
            ctx.addPath(ChatMarkGeometry.tailPath(in: art))
            ctx.setFillColor(NSColor(srgbRed: 0.36, green: 0.85, blue: 0.55, alpha: 1).cgColor)
            ctx.fillPath()
            return true
        }
    }
}

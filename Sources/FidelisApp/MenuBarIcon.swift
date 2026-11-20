import AppKit

/// The menu bar glyph: an "F" monogram in a rounded square, drawn as paths so it is exactly
/// centred at any scale. Template image, so macOS tints it for light and dark menu bars.
enum MenuBarIcon {
    enum Style { case outline, solid }

    static let size = NSSize(width: 18, height: 18)

    static func image(_ style: Style, alpha: CGFloat = 1) -> NSImage {
        let img = NSImage(size: size, flipped: false) { _ in
            draw(style, alpha: alpha)
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Fidelis"
        return img
    }

    static func draw(_ style: Style, alpha: CGFloat) {
        let box = NSRect(x: 1.5, y: 1.5, width: 15, height: 15)
        let radius: CGFloat = 4
        NSColor.black.withAlphaComponent(alpha).set()
        let f = monogram(in: box)

        switch style {
        case .outline:
            let outline = NSBezierPath(roundedRect: box.insetBy(dx: 0.75, dy: 0.75), xRadius: radius - 0.75, yRadius: radius - 0.75)
            outline.lineWidth = 1.5
            outline.stroke()
            f.fill()
        case .solid:
            NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius).fill()
            let ctx = NSGraphicsContext.current!.cgContext
            ctx.saveGState()
            ctx.setBlendMode(.destinationOut)
            NSColor.black.set()
            f.fill()
            ctx.restoreGState()
        }
    }

    /// An F of three capsules (stem, top arm, shorter middle arm). Its bounding box is centred in
    /// `box`, nudged right by a quarter point because the open right side reads lighter.
    private static func monogram(in box: NSRect) -> NSBezierPath {
        let t: CGFloat = 2.2            // stroke thickness
        let height: CGFloat = 8.6
        let top: CGFloat = 6.3, middle: CGFloat = 4.6
        let x0 = box.midX - top / 2 + 0.25
        let y0 = box.midY - height / 2
        func capsule(_ r: NSRect) -> NSBezierPath { NSBezierPath(roundedRect: r, xRadius: t / 2, yRadius: t / 2) }
        let p = NSBezierPath()
        p.append(capsule(NSRect(x: x0, y: y0, width: t, height: height)))
        p.append(capsule(NSRect(x: x0, y: y0 + height - t, width: top, height: t)))
        p.append(capsule(NSRect(x: x0, y: y0 + height / 2 - t / 2 + 0.4, width: middle, height: t)))
        p.windingRule = .nonZero
        return p
    }
}

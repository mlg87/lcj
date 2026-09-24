/// ProviderGlyph.swift — the provider marks, shared by the menu bar and the
/// dropdown cards so both draw the same ✻ and blossom.

import AppKit

enum ProviderGlyph {
    /// Claude Code's own spinner glyph — familiar to the people this app is for.
    static func drawClaude(center: NSPoint, fontSize: CGFloat, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium), .foregroundColor: color]
        let str = "✻" as NSString
        let size = str.size(withAttributes: attrs)
        str.draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: attrs)
    }

    /// Simplified OpenAI blossom: six rounded petals rotated 60° apart. Drawn as
    /// vector so it stays monochrome and matches the ✻ (no emoji exists for it).
    /// Symmetric under a vertical flip, so it draws correctly in flipped views.
    static func drawCodex(center: NSPoint, diameter: CGFloat, color: NSColor) {
        let petalW = diameter * 0.28
        let petalH = diameter * 0.92
        color.setFill()
        for i in 0..<6 {
            let rect = NSRect(x: -petalW / 2, y: -petalH / 2, width: petalW, height: petalH)
            let petal = NSBezierPath(roundedRect: rect, xRadius: petalW / 2, yRadius: petalW / 2)
            petal.transform(using: AffineTransform(rotationByDegrees: CGFloat(i) * 60))
            petal.transform(using: AffineTransform(translationByX: center.x, byY: center.y))
            petal.fill()
        }
    }
}

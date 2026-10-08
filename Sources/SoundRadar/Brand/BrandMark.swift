import SwiftUI
import AppKit

/// Sound Radar brand mark, geometry in a 64x64 box (y down).
enum MarkPath {
    static let slatW = 35.5556, slatH = 8.88891, slatR = 0.740743
    static let arcs: [(from: CGPoint, to: CGPoint, r: CGFloat)] = [
        (CGPoint(x: 28.9, y: 24.6), CGPoint(x: 30.4, y: 29.7), 15),
        (CGPoint(x: 35.6, y: 21.3), CGPoint(x: 37.9, y: 28.9), 22.5),
        (CGPoint(x: 42.3, y: 18.0), CGPoint(x: 45.3, y: 28.1), 30),
    ]

    /// The three slats, filled, in the 64-unit box.
    static func slats() -> CGPath {
        let path = CGMutablePath()
        func slat(_ y: CGFloat) -> CGRect { CGRect(x: 14, y: y, width: slatW, height: slatH) }
        path.addRoundedRect(in: slat(43.1113), cornerWidth: slatR, cornerHeight: slatR)
        path.addRoundedRect(in: slat(32.7402), cornerWidth: slatR, cornerHeight: slatR)
        // Top slat rotated -34 degrees around (14, 31), y down.
        var t = CGAffineTransform(translationX: 14, y: 31)
            .rotated(by: -34 * .pi / 180)
            .translatedBy(x: -14, y: -31)
        if let top = CGPath(roundedRect: slat(22.11), cornerWidth: slatR, cornerHeight: slatR,
                            transform: nil).copy(using: &t) {
            path.addPath(top)
        }
        return path
    }

    /// Wave arc `i` (0...2) as a stroked-line path (stroke width 2.6, round caps).
    static func arc(_ i: Int) -> CGPath {
        let a = arcs[i]
        // SVG arc: A r r 0 0 1 (sweep=1, small arc) -> centre on the left of the chord.
        let mid = CGPoint(x: (a.from.x + a.to.x) / 2, y: (a.from.y + a.to.y) / 2)
        let dx = a.to.x - a.from.x, dy = a.to.y - a.from.y
        let d = hypot(dx, dy)
        let h = sqrt(max(a.r * a.r - d * d / 4, 0))
        // Sweep 1 (clockwise on screen, y down), small arc: centre is at mid - perp*h,
        // with perp = (-dy, dx)/d... pick the candidate centre reproducing sweep 1.
        let c = CGPoint(x: mid.x - dy / d * h, y: mid.y + dx / d * h)
        let s = atan2(a.from.y - c.y, a.from.x - c.x)
        let e = atan2(a.to.y - c.y, a.to.x - c.x)
        let p = CGMutablePath()
        // clockwise:false in CG with a y-down (flipped) context equals visual clockwise.
        p.addArc(center: c, radius: a.r, startAngle: s, endAngle: e, clockwise: false)
        return p
    }

    static let strokeWidth: CGFloat = 2.6
}

/// Draws the mark into a y-down 64-unit box mapped onto `rect`.
struct SoundRadarMark: View {
    var waves: Int = 3
    var color: Color = .primary

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 64
            var t = CGAffineTransform(translationX: (size.width - 64 * s) / 2,
                                      y: (size.height - 64 * s) / 2).scaledBy(x: s, y: s)
            if let slats = MarkPath.slats().copy(using: &t) {
                ctx.fill(Path(slats), with: .color(color))
            }
            for i in 0..<max(0, min(3, waves)) {
                if let arc = MarkPath.arc(i).copy(using: &t) {
                    ctx.stroke(Path(arc), with: .color(color),
                               style: StrokeStyle(lineWidth: MarkPath.strokeWidth * s, lineCap: .round))
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// 18x18 pt template image for the menu bar.
func makeMenuBarImage(waves: Int, playing: Bool = false) -> NSImage {
    let size = NSSize(width: 18, height: 18)
    let image = NSImage(size: size, flipped: true) { rect in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        // Mark occupies x 2.8...46, y 3.8...52; show the box 1.5...51.5 x 3.5...53.5.
        let s = rect.width / 50
        ctx.saveGState()
        ctx.translateBy(x: -1.5 * s, y: -3.5 * s)
        ctx.scaleBy(x: s, y: s)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.addPath(MarkPath.slats())
        ctx.fillPath()
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineCap(.round)
        ctx.setLineWidth(MarkPath.strokeWidth)
        for i in 0..<max(0, min(3, waves)) {
            ctx.addPath(MarkPath.arc(i))
            ctx.strokePath()
        }
        ctx.restoreGState()
        return true
    }
    image.isTemplate = true
    return image
}

// Renders the DMG window background: black stage, Fuego pixel confetti, headline, pixel arrow.
// Usage: swift tools/make-dmg-background.swift <out-dir>
// Writes background.png (660x420) and background@2x.png (1320x840); make-dmg.sh merges them into a TIFF.
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let W: CGFloat = 660, H: CGFloat = 420

func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: a)
}
let palette: [UInt32] = [0xFF5500, 0xFF96D6, 0xFFC0CF, 0xFFE27A, 0xFFFFFF, 0x28C840]

// Deterministic LCG so every build draws the same confetti.
var seed: UInt64 = 20261008
func rnd() -> CGFloat { seed = (seed &* 1103515245 &+ 12345) % 2147483648; return CGFloat(seed) / 2147483648 }

func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gc
    let ctx = gc.cgContext
    // y-down coordinates like the design.
    ctx.translateBy(x: 0, y: H); ctx.scaleBy(x: 1, y: -1)

    hex(0x0B0B0B).setFill(); CGRect(x: 0, y: 0, width: W, height: H).fill()

    // One soft spotlight behind the headline.
    let space = CGColorSpaceCreateDeviceRGB()
    let glow = CGGradient(colorsSpace: space, colors: [hex(0xF7F1E5, 0.13).cgColor, hex(0xF7F1E5, 0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 330, y: 20), startRadius: 0, endCenter: CGPoint(x: 330, y: 20), endRadius: 230, options: [])

    // Confetti, kept clear of the two icon wells and the headline.
    seed = 20261008
    var placed = 0
    ctx.setShouldAntialias(false)
    while placed < 70 {
        let x = floor(rnd() * 640) + 6, y = floor(rnd() * 400) + 6
        let s = [4, 6, 8][Int(rnd() * 3) % 3] as CGFloat
        let c = palette[Int(rnd() * CGFloat(palette.count)) % palette.count]
        let rot = [0, 0, 45, 15][Int(rnd() * 4) % 4] as CGFloat
        let a = 0.55 + rnd() * 0.45
        let inWell = (abs(x - 170) < 90 && abs(y - 225) < 90) || (abs(x - 490) < 90 && abs(y - 225) < 90)
        let inText = y > 28 && y < 98 && x > 140 && x < 520
        let onArrow = x > 262 && x < 396 && y > 190 && y < 258
        let onPlate = abs(y - 307) < 20 && (abs(x - 170) < 80 || abs(x - 490) < 80)
        if inWell || inText || onArrow || onPlate { continue }
        ctx.saveGState()
        ctx.translateBy(x: x + s / 2, y: y + s / 2)
        ctx.rotate(by: rot * .pi / 180)
        hex(c, a).setFill()
        CGRect(x: -s / 2, y: -s / 2, width: s, height: s).fill()
        ctx.restoreGState()
        placed += 1
    }

    // Pixel arrow from the app well to the Applications well.
    let arrowColours: [UInt32] = [0xFF5500, 0xFF5500, 0xFF96D6, 0xFF96D6, 0xFFE27A, 0xFFE27A]
    for i in 0..<12 {
        hex(arrowColours[i / 2]).setFill()
        CGRect(x: 276 + CGFloat(i) * 9, y: 221, width: 8, height: 8).fill()
    }
    hex(0xFFE27A).setFill()
    for p in [(375, 212), (375, 230), (366, 203), (366, 239)] {
        CGRect(x: CGFloat(p.0), y: CGFloat(p.1), width: 8, height: 8).fill()
    }
    ctx.setShouldAntialias(true)

    // The system Applications icon under Finder's own: Finder often leaves the /Applications link blank in a DMG.
    let apps = NSWorkspace.shared.icon(forFile: "/Applications")
    apps.size = NSSize(width: 128, height: 128)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    apps.draw(in: CGRect(x: 490 - 64, y: 225 - 64, width: 128, height: 128), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)])
    NSGraphicsContext.restoreGraphicsState()

    // Cream plates under Finder's item labels: Finder draws them in dark text, which vanishes on the black stage.
    hex(0xF3EBDD).setFill()
    for cx in [170.0, 490.0] as [CGFloat] {
        NSBezierPath(roundedRect: CGRect(x: cx - 66, y: 296, width: 132, height: 22), xRadius: 11, yRadius: 11).fill()
    }

    // Text is drawn in a flipped context so it reads upright.
    let flipped = NSGraphicsContext(cgContext: ctx, flipped: true)
    NSGraphicsContext.current = flipped
    let centered = NSMutableParagraphStyle(); centered.alignment = .center
    let head = NSFont(name: "HostGrotesk-ExtraBold", size: 26) ?? .systemFont(ofSize: 26, weight: .heavy)
    let serifDesc = NSFont.systemFont(ofSize: 26).fontDescriptor.withDesign(.serif)?.withSymbolicTraits(.italic)
    let serif = serifDesc.flatMap { NSFont(descriptor: $0, size: 26) } ?? .systemFont(ofSize: 26)
    NSAttributedString(string: "Drag the speaker to Applications.", attributes: [
        .font: head, .foregroundColor: hex(0xF7F1E5), .kern: -0.8, .paragraphStyle: centered,
    ]).draw(in: CGRect(x: 0, y: 34, width: W, height: 34))
    NSAttributedString(string: "Turn it up.", attributes: [
        .font: serif, .foregroundColor: hex(0xFF96D6), .paragraphStyle: centered,
    ]).draw(in: CGRect(x: 0, y: 64, width: W, height: 34))
    let foot = NSFont(name: "HostGrotesk-Regular", size: 11) ?? .systemFont(ofSize: 11)
    NSAttributedString(string: "FUEGO.WTF  ·  PRODUCTS THAT MAKE PEOPLE SAY WTF", attributes: [
        .font: foot, .foregroundColor: hex(0xF7F1E5, 0.55), .kern: 2.0, .paragraphStyle: centered,
    ]).draw(in: CGRect(x: 0, y: H - 36, width: W, height: 16))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (scale, name) in [(1.0, "background.png"), (2.0, "background@2x.png")] {
    let rep = render(scale: scale)
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("wrote \(url.path)")
}

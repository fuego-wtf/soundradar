// Renders the Sound Radar app icon PNGs. Usage: swift tools/make-icon.swift <outdir>
// Writes AppIcon.iconset-style files (icon_16x16.png ... icon_512x512@2x.png) into <outdir>.
// import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Geometry duplicated from Sources/SoundRadar/Brand/BrandMark.swift (PixelSpeaker).
let speakerRows = [
    "................",
    "................",
    ".......O........",
    "......OO....O...",
    ".....OPO.....O..",
    "....OPLO..P...O.",
    "OOOOPLLO...P..O.",
    "OYYPLLYO...P...O",
    "OYYPLLYO...P...O",
    "OOOOPLLO...P..O.",
    "....OPLO..P...O.",
    ".....OPO.....O..",
    "......OO....O...",
    ".......O........",
    "................",
    "................",
]
let speakerColors: [Character: UInt32] = ["O": 0xFF5500, "P": 0xFF96D6, "L": 0xFFC0CF, "Y": 0xFFE27A]

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}

/// Continuous-corner (superellipse-like) rounded square.
func squircle(_ rect: CGRect, radius: CGFloat) -> CGPath {
    let n = 5.0
    let a = rect.width / 2, b = rect.height / 2
    let p = CGMutablePath()
    let steps = 720
    // Blend: superellipse body keeps the 22.37% corner feel.
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = rect.midX + a * CGFloat(copysign(pow(abs(ct), 2 / n), ct))
        let y = rect.midY + b * CGFloat(copysign(pow(abs(st), 2 / n), st))
        if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
    }
    p.closeSubpath()
    return p
}

func render(px: Int) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Work in a 1024 y-down space.
    let k = CGFloat(px) / 1024
    ctx.scaleBy(x: k, y: -k)
    ctx.translateBy(x: 0, y: -1024)
    ctx.setShouldAntialias(true)

    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(tile, radius: 824 * 0.2237)
    // Hard offset shadow.
    ctx.saveGState()
    ctx.translateBy(x: 16, y: 16)
    ctx.addPath(shape); ctx.setFillColor(rgb(0x141414)); ctx.fillPath()
    ctx.restoreGState()
    // Tile + border.
    ctx.addPath(shape); ctx.setFillColor(rgb(0x0B0B0B)); ctx.fillPath()
    ctx.addPath(shape); ctx.setStrokeColor(rgb(0x141414)); ctx.setLineWidth(12); ctx.strokePath()
    // (stroke is centred on the edge; inner 6 px is the visible border)

    // Speaker: integer cell size (40 px at 1024), rounded down at smaller sizes, centred.
    // Work in device pixels so every cell rect lands on whole pixels.
    ctx.interpolationQuality = .none
    ctx.setShouldAntialias(false)
    let cell = max(1, Int((CGFloat(px) * 40 / 1024).rounded(.down)))
    let art = cell * 16
    let origin = (px - art) / 2
    ctx.saveGState()
    ctx.concatenate(ctx.ctm.inverted()) // device pixels
    ctx.translateBy(x: 0, y: CGFloat(px)); ctx.scaleBy(x: 1, y: -1) // y-down
    for (y, row) in speakerRows.enumerated() {
        for (x, ch) in row.enumerated() {
            guard let c = speakerColors[ch] else { continue }
            ctx.setFillColor(rgb(c))
            ctx.fill(CGRect(x: origin + x * cell, y: origin + y * cell, width: cell, height: cell))
        }
    }
    ctx.restoreGState()
    return ctx.makeImage()!
}

func write(_ img: CGImage, to url: URL) {
    let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, img, nil)
    guard CGImageDestinationFinalize(d) else { fatalError("write failed: \(url.path)") }
}

guard CommandLine.arguments.count > 1 else { print("usage: make-icon.swift <outdir>"); exit(2) }
let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    write(render(px: base), to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    write(render(px: base * 2), to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
write(render(px: 1024), to: out.appendingPathComponent("AppIcon-1024.png"))

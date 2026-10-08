// Renders the Sound Radar app icon PNGs. Usage: swift tools/make-icon.swift <outdir>
// Writes AppIcon.iconset-style files (icon_16x16.png ... icon_512x512@2x.png) into <outdir>.
// Geometry duplicated from Sources/SoundRadar/Brand/BrandMark.swift (this script cannot import the app).
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let slatW = 35.5556, slatH = 8.88891, slatR = 0.740743
let arcs: [(CGPoint, CGPoint, CGFloat)] = [
    (CGPoint(x: 28.9, y: 24.6), CGPoint(x: 30.4, y: 29.7), 15),
    (CGPoint(x: 35.6, y: 21.3), CGPoint(x: 37.9, y: 28.9), 22.5),
    (CGPoint(x: 42.3, y: 18.0), CGPoint(x: 45.3, y: 28.1), 30),
]

func slatsPath() -> CGPath {
    let p = CGMutablePath()
    func slat(_ y: CGFloat) -> CGRect { CGRect(x: 14, y: y, width: slatW, height: slatH) }
    p.addRoundedRect(in: slat(43.1113), cornerWidth: slatR, cornerHeight: slatR)
    p.addRoundedRect(in: slat(32.7402), cornerWidth: slatR, cornerHeight: slatR)
    var t = CGAffineTransform(translationX: 14, y: 31).rotated(by: -34 * .pi / 180).translatedBy(x: -14, y: -31)
    if let top = CGPath(roundedRect: slat(22.11), cornerWidth: slatR, cornerHeight: slatR, transform: nil).copy(using: &t) {
        p.addPath(top)
    }
    return p
}

func arcPath(_ i: Int) -> CGPath {
    let (f, to, r) = arcs[i]
    let mid = CGPoint(x: (f.x + to.x) / 2, y: (f.y + to.y) / 2)
    let dx = to.x - f.x, dy = to.y - f.y
    let d = hypot(dx, dy)
    let h = sqrt(max(r * r - d * d / 4, 0))
    let c = CGPoint(x: mid.x - dy / d * h, y: mid.y + dx / d * h)
    let p = CGMutablePath()
    p.addArc(center: c, radius: r, startAngle: atan2(f.y - c.y, f.x - c.x),
             endAngle: atan2(to.y - c.y, to.x - c.x), clockwise: false)
    return p
}

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

    // Mark: 64 units -> 640 px, centred on the tile.
    let s: CGFloat = 10
    ctx.saveGState()
    ctx.translateBy(x: 512 - 32 * s, y: 512 - 32 * s)
    ctx.scaleBy(x: s, y: s)
    ctx.setFillColor(rgb(0xF7F1E5)); ctx.addPath(slatsPath()); ctx.fillPath()
    ctx.setStrokeColor(rgb(0xF7F1E5)); ctx.setLineWidth(2.6); ctx.setLineCap(.round)
    for i in 0..<3 { ctx.addPath(arcPath(i)); ctx.strokePath() }
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

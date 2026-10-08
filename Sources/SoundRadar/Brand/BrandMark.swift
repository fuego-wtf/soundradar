import SwiftUI
import AppKit

/// The Sound Radar mark: a 16x16 pixel-art speaker with two sound waves.
/// Cells with x <= 7 are the speaker; 'P' cells with x >= 9 are wave 1 (inner);
/// 'O' cells with x >= 12 are wave 2 (outer).
enum PixelSpeaker {
    static let size = 16
    static let rows: [String] = [
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

    static let palette: [Character: UInt32] = [
        "O": 0xFF5500, "P": 0xFF96D6, "L": 0xFFC0CF, "Y": 0xFFE27A,
    ]

    struct Cell {
        let x: Int, y: Int
        let key: Character
        /// 0 = speaker, 1 = inner wave, 2 = outer wave.
        let wave: Int
    }

    static let cells: [Cell] = {
        var out: [Cell] = []
        for (y, row) in rows.enumerated() {
            for (x, ch) in row.enumerated() where ch != "." {
                let wave = x <= 7 ? 0 : (x >= 12 ? 2 : 1)
                out.append(Cell(x: x, y: y, key: ch, wave: wave))
            }
        }
        return out
    }()

    /// Cells visible with `waves` waves (0, 1 or 2; other values are clamped).
    static func cells(waves: Int) -> [Cell] {
        let w = max(0, min(2, waves))
        return cells.filter { $0.wave <= w }
    }

    static func rgb(_ key: Character) -> (r: Double, g: Double, b: Double) {
        let v = palette[key] ?? 0
        return (Double((v >> 16) & 255) / 255, Double((v >> 8) & 255) / 255, Double(v & 255) / 255)
    }
}

/// Draws the speaker with one Canvas; every cell is an integer-aligned rect.
struct SoundRadarMark: View {
    var waves: Int = 2
    /// When set, every cell is drawn in this one colour (template contexts).
    var monochrome: Color? = nil

    var body: some View {
        Canvas { ctx, size in
            let cell = max(1, (min(size.width, size.height) / CGFloat(PixelSpeaker.size)).rounded(.down))
            let art = cell * CGFloat(PixelSpeaker.size)
            let ox = ((size.width - art) / 2).rounded(.down)
            let oy = ((size.height - art) / 2).rounded(.down)
            for c in PixelSpeaker.cells(waves: waves) {
                let rect = CGRect(x: ox + CGFloat(c.x) * cell, y: oy + CGFloat(c.y) * cell,
                                  width: cell, height: cell)
                let color: Color
                if let monochrome {
                    color = monochrome
                } else {
                    let t = PixelSpeaker.rgb(c.key)
                    color = Color(.sRGB, red: t.r, green: t.g, blue: t.b)
                }
                ctx.fill(Path(rect), with: .color(color))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// 18x18 pt template image for the menu bar: black cells only, cell = 1 pt,
/// the 16x16 grid centred with a 1 pt margin (whole pixels at 1x and 2x).
func makeMenuBarImage(waves: Int, playing: Bool = false) -> NSImage {
    let size = NSSize(width: 18, height: 18)
    let image = NSImage(size: size, flipped: true) { _ in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        ctx.setShouldAntialias(false)
        ctx.setFillColor(NSColor.black.cgColor)
        for c in PixelSpeaker.cells(waves: waves) {
            ctx.fill(CGRect(x: 1 + c.x, y: 1 + c.y, width: 1, height: 1))
        }
        return true
    }
    image.isTemplate = true
    return image
}

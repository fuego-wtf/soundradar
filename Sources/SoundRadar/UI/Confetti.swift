import SwiftUI

/// One-time pixel confetti burst for the first launch. A single Canvas draws every piece,
/// and the overlay removes itself from the hierarchy when the burst ends.
struct ConfettiBurst: View {
    static let duration: TimeInterval = 2.2
    static let defaultsKey = "celebrated.v1"
    private static let palette: [Color] = [
        Color(hex: 0xFF5500), Color(hex: 0xFF96D6), Color(hex: 0xFFC0CF),
        Color(hex: 0xFFE27A), Color(hex: 0xFFFFFF), Color(hex: 0x28C840),
    ]

    struct Piece {
        var angle: Double, speed: Double, size: Double, spin: Double, phase: Double, drift: Double
        var color: Int
    }

    private let pieces: [Piece]
    private let start = Date()
    var onFinish: () -> Void

    init(count: Int = 120, onFinish: @escaping () -> Void) {
        var g = SystemRandomNumberGenerator()
        pieces = (0..<count).map { _ in
            Piece(angle: Double.random(in: (.pi * 0.12)...(.pi * 0.88), using: &g),
                  speed: Double.random(in: 260...760, using: &g),
                  size: [4.0, 6.0, 8.0].randomElement(using: &g)!,
                  spin: Double.random(in: -5...5, using: &g),
                  phase: Double.random(in: 0...(.pi * 2), using: &g),
                  drift: Double.random(in: -40...40, using: &g),
                  color: Int.random(in: 0..<Self.palette.count, using: &g))
        }
        self.onFinish = onFinish
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSince(start)
            Canvas { ctx, size in
                guard t < Self.duration else { return }
                let origin = CGPoint(x: size.width / 2, y: -8)
                let fade = min(1, max(0, (Self.duration - t) / 0.7))
                for p in pieces {
                    // Ballistic burst with drag-free gravity, a little sideways wobble and spin.
                    let x = origin.x + cos(p.angle) * p.speed * t * 0.9 * (1 - 0.25 * t) + p.drift * t
                    let y = origin.y + sin(p.angle) * p.speed * t * 0.55 + 620 * t * t
                    let rect = CGRect(x: -p.size / 2, y: -p.size / 2, width: p.size, height: p.size)
                    var c = ctx
                    c.translateBy(x: x.rounded(), y: y.rounded())
                    c.rotate(by: .radians(p.phase + p.spin * t))
                    c.opacity = fade
                    c.fill(Path(rect), with: .color(Self.palette[p.color]))
                }
            }
            .task(id: t >= Self.duration) { if t >= Self.duration { onFinish() } }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Shows the burst once, the first time the main window appears.
struct FirstLaunchConfetti: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var active = false

    func body(content: Content) -> some View {
        content
            .overlay { if active { ConfettiBurst { active = false } } }
            .onAppear {
                let d = UserDefaults.standard
                guard !d.bool(forKey: ConfettiBurst.defaultsKey) else { return }
                d.set(true, forKey: ConfettiBurst.defaultsKey)
                if !reduceMotion { active = true }
            }
    }
}

extension View {
    func firstLaunchConfetti() -> some View { modifier(FirstLaunchConfetti()) }
}

import SwiftUI

/// Everything about one sound source: where it is, how loud, and the controls.
struct SourceDetail: View {
    let app: AppRow
    let model: RadarModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                AppIconView(app: app, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name).font(.title3.weight(.semibold))
                    Text(app.isPlaying ? "Playing now" : "Played a moment ago")
                        .font(.caption).foregroundStyle(app.isPlaying ? Color.sound : .secondary)
                }
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.glass).controlSize(.small)
                    .accessibilityLabel("Back to radar")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Exactly where").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
                    row("Tab", app.location?.tabTitle, sub: app.location?.tabURL)
                    row("Window", app.location?.windowTitle)
                    row("Display", displayName)
                    row("Desktop", app.location?.space.detailText)
                    row("Process", processText)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Level, last 30 seconds").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                HistoryBars(model: model, pid: app.id)
                    .frame(height: 36)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Volume").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                LevelMeter(model: model, pid: app.id)
                VolumeSlider(app: app, model: model)
                PermissionHint(model: model)
            }

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button { model.jump(to: app) } label: {
                        Label(app.location?.tabTitle != nil ? "Go to tab" : "Go to", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.glassProminent).tint(.sound)
                    MuteButton(app: app, model: model)
                    SoloButton(app: app, model: model)
                }
            }
        }
        .padding(16)
    }

    private var displayName: String? {
        let line = model.whereIs(app)
        return line == "no visible window" ? nil : line.replacingOccurrences(of: "on the ", with: "").replacingOccurrences(of: "on ", with: "")
    }

    private var processText: String {
        let helper = app.helpers.sorted().first
        let pid = app.helperPIDs.first ?? app.id
        return "\(helper ?? app.name) · pid \(pid)"
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?, sub: String? = nil) -> some View {
        GridRow {
            Text(label).font(.callout).foregroundStyle(.secondary).gridColumnAlignment(.leading)
            VStack(alignment: .leading, spacing: 0) {
                Text(value ?? "Unknown").font(.callout).foregroundStyle(value == nil ? .tertiary : .primary)
                    .lineLimit(2)
                if let sub { Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
    }
}

struct SoloButton: View {
    let app: AppRow
    let model: RadarModel
    @Environment(SoloCoordinator.self) private var solo

    var body: some View {
        VolumeGate(model: model) { allowed in
            Button { solo.toggle(app, model: model) } label: {
                Label(solo.soloed == app.id ? "Unsolo" : "Solo", systemImage: "headphones")
            }
            .buttonStyle(.glass)
            .disabled(!allowed)
        }
    }
}

/// Fixed-size ring of the last 60 level samples (30 s at 2 Hz); plain storage, no observation.
final class LevelRing {
    static let capacity = 60
    private var storage = [Float](repeating: -120, count: capacity)
    private var head = 0
    private(set) var count = 0

    func reset() { head = 0; count = 0 }

    func push(_ db: Float) {
        storage[head] = db
        head = (head + 1) % Self.capacity
        count = min(count + 1, Self.capacity)
    }

    /// Samples oldest to newest.
    func sample(at i: Int) -> Float {
        storage[(head - count + i + Self.capacity * 2) % Self.capacity]
    }
}

/// Samples the source's level twice a second into a ring and draws it with one Canvas. Owns its own
/// sampling task, so a tick re-evaluates this leaf only.
struct HistoryBars: View {
    let model: RadarModel
    let pid: pid_t
    @State private var ring = LevelRing()
    @State private var tick = 0

    var body: some View {
        Canvas { ctx, size in
            _ = tick
            let barW: CGFloat = 4, gap: CGFloat = 1.5
            let n = ring.count
            for i in 0..<n {
                let db = ring.sample(at: i)
                let frac = db <= -60 ? 0.04 : CGFloat((min(db, 0) + 60) / 60)
                let h = max(2, size.height * frac)
                let x = size.width - CGFloat(n - i) * (barW + gap) + gap
                ctx.fill(Path(roundedRect: CGRect(x: x, y: size.height - h, width: barW, height: h), cornerRadius: 1),
                         with: .color(Color.sound.opacity(0.35 + 0.65 * frac)))
            }
        }
        .task(id: pid) {
            ring.reset()
            while !Task.isCancelled {
                ring.push(model.mixer.level(for: pid))
                tick &+= 1
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }
}

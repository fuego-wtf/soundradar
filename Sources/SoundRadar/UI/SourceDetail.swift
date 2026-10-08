import SwiftUI

/// Everything about one sound source: where it is, how loud, and the controls.
struct SourceDetail: View {
    let app: AppRow
    let model: RadarModel
    let close: () -> Void
    @Environment(SoloCoordinator.self) private var solo
    @State private var history: [Float] = []

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
                HistoryBars(samples: history)
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
                    Button { solo.toggle(app, model: model) } label: {
                        Label(solo.soloed == app.id ? "Unsolo" : "Solo", systemImage: "headphones")
                    }
                    .buttonStyle(.glass)
                    .disabled(!model.volumeControlEnabled)
                }
            }
        }
        .padding(16)
        .task(id: app.id) {
            history = []
            while !Task.isCancelled {
                history.append(model.mixer.level(for: app.id))
                if history.count > 60 { history.removeFirst(history.count - 60) }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
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

struct HistoryBars: View {
    let samples: [Float]

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(Array(samples.enumerated()), id: \.offset) { _, db in
                    let frac = db <= -60 ? 0.04 : CGFloat((min(db, 0) + 60) / 60)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.sound.opacity(0.35 + 0.65 * frac))
                        .frame(height: max(2, geo.size.height * frac))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
    }
}

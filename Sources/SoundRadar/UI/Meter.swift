import SwiftUI

/// 24 thin segments, -60...0 dBFS, green then yellow then red. Level -120 (silence or unknown) lights
/// nothing. Only the Canvas sits inside the 30 fps timeline, and it pauses when its card is off screen.
struct LevelMeter: View {
    let model: RadarModel
    let pid: pid_t

    static let segments = 24
    static let height: CGFloat = 4

    static func litSegments(db: Float) -> Int {
        guard db > -60 else { return 0 }
        let frac = (min(db, 0) + 60) / 60
        return max(1, Int((frac * Float(segments)).rounded(.up)))
    }

    static func color(_ i: Int) -> Color {
        i < 16 ? .playing : (i < 21 ? .justHeard : .muted)
    }

    var body: some View {
        VolumeGate(model: model) { allowed in
            MeterBars(model: model, pid: pid, active: allowed)
        }
        .frame(height: Self.height)
        .accessibilityHidden(true)
    }
}

private struct MeterBars: View {
    let model: RadarModel
    let pid: pid_t
    let active: Bool
    @State private var onScreen = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !onScreen)) { timeline in
            Canvas { ctx, size in
                _ = timeline.date
                let n = LevelMeter.segments
                let gap: CGFloat = 2
                let w = max(1, (size.width - gap * CGFloat(n - 1)) / CGFloat(n))
                let lit = (active && !model.mixer.isMuted(pid))
                    ? LevelMeter.litSegments(db: model.mixer.level(for: pid)) : 0
                let off = active ? Color.primary.opacity(0.12) : Color.needsPermission.opacity(0.3)
                for i in 0..<n {
                    let rect = CGRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: size.height)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(i < lit ? LevelMeter.color(i) : off))
                }
            }
        }
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
    }
}

/// Slider 0...150 % on a binding the owner holds, so keys and the slider share one value.
struct VolumeControl: View {
    let app: AppRow
    let model: RadarModel
    @Binding var volume: Double
    @State private var editing = false
    @State private var editEndedAt: TimeInterval = -.infinity

    var body: some View {
        HStack(spacing: 8) {
            VolumeGate(model: model) { allowed in
                Slider(value: $volume, in: 0...1.5) { isEditing in
                    editing = isEditing
                    if !isEditing { editEndedAt = ProcessInfo.processInfo.systemUptime }
                }
                .tint(.playing)
                .controlSize(.small)
                .disabled(!allowed)
                .accessibilityLabel("\(app.name) volume")
                .accessibilityValue("\(Int((volume * 100).rounded())) percent")
            }
            Text("\(Int((volume * 100).rounded()))%")
                .font(.num(12))
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
        .onAppear { volume = Double(model.mixer.volume(for: app.id)) }
        .onChange(of: volume) { _, v in
            // Written through on every change, no debounce. Only write what differs, so a
            // refresh from the mixer never echoes back.
            if abs(model.mixer.volume(for: app.id) - Float(v)) > 0.0005 { model.mixer.setVolume(Float(v), for: app.id) }
        }
        .onScan(model) {
            // Never re-sync while dragging or within 500 ms after, or the thumb jumps back.
            guard !editing, ProcessInfo.processInfo.systemUptime - editEndedAt > 0.5 else { return }
            let v = Double(model.mixer.volume(for: app.id))
            if v != volume { volume = v }
        }
    }
}

/// `VolumeControl` that owns its value (detail view, menu bar).
struct VolumeSlider: View {
    let app: AppRow
    let model: RadarModel
    @State private var volume: Double = 1

    var body: some View { VolumeControl(app: app, model: model, volume: $volume) }
}

/// Glass mute button on a binding; red when muted.
struct MuteButton: View {
    let app: AppRow
    let model: RadarModel
    @Binding var muted: Bool
    var showsTitle = false

    var body: some View {
        VolumeGate(model: model) { allowed in
            Button { muted.toggle() } label: {
                if showsTitle {
                    Label(muted ? "Unmute" : "Mute", systemImage: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                } else {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(width: 16, height: 16)
                }
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .tint(muted ? Color.muted : nil)
            .foregroundStyle(muted ? Color.muted : Color.primary)
            .disabled(!allowed)
            .accessibilityLabel(muted ? "Unmute \(app.name)" : "Mute \(app.name)")
            .help(muted ? "Unmute (M)" : "Mute (M)")
        }
        .onAppear { muted = model.mixer.isMuted(app.id) }
        .onChange(of: muted) { _, m in
            if model.mixer.isMuted(app.id) != m { model.mixer.setMuted(m, for: app.id) }
        }
        .onScan(model) {
            let m = model.mixer.isMuted(app.id)
            if m != muted { muted = m }
        }
    }
}

/// `MuteButton` that owns its state (detail view, menu bar).
struct MuteControl: View {
    let app: AppRow
    let model: RadarModel
    var showsTitle = false
    @State private var muted = false

    var body: some View { MuteButton(app: app, model: model, muted: $muted, showsTitle: showsTitle) }
}

/// Master volume of the default output device. Same drag rule as `VolumeControl`: no refresh while dragging.
struct MasterVolumeSlider: View {
    private let output = OutputDevice.shared
    @State private var volume: Double = 0
    @State private var editing = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: volume <= 0.001 ? "speaker.fill" : "speaker.wave.2.fill")
                .foregroundStyle(.secondary).frame(width: 18)
                .accessibilityHidden(true)
            Slider(value: $volume, in: 0...1) { editing = $0 }
                .tint(.playing)
                .controlSize(.small)
                .disabled(!output.canSetVolume)
                .accessibilityLabel("Master volume")
                .accessibilityValue("\(Int((volume * 100).rounded())) percent")
            Text(output.volume == nil ? "n/a" : "\(Int((volume * 100).rounded()))%")
                .font(.num(12)).foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
        .onAppear { volume = Double(output.volume ?? 0) }
        .onChange(of: volume) { _, v in
            if editing || abs(Float(v) - (output.volume ?? 0)) > 0.002 { output.setVolume(Float(v)) }
        }
        .onChange(of: output.volume) { _, v in if !editing { volume = Double(v ?? 0) } }
    }
}

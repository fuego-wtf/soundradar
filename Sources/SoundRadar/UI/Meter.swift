import SwiftUI

/// 20 segments, -60...0 dBFS, green then orange then red. Level -120 (silence or unknown) lights nothing.
/// Only the Canvas sits inside the 20 Hz timeline; nothing else is re-evaluated per frame.
struct LevelMeter: View {
    let model: RadarModel
    let pid: pid_t
    var segmentSize = CGSize(width: 6, height: 10)

    static let segments = 20
    private static let gap: CGFloat = 2

    static func litSegments(db: Float) -> Int {
        guard db > -60 else { return 0 }
        let frac = (min(db, 0) + 60) / 60
        return max(1, Int((frac * Float(segments)).rounded(.up)))
    }

    var body: some View {
        VolumeGate(model: model) { allowed in
            MeterBars(model: model, pid: pid, active: allowed, segmentSize: segmentSize)
                .opacity(allowed ? 1 : 0.4)
                .overlay {
                    if !allowed {
                        Text("needs permission").font(.caption2).foregroundStyle(.secondary)
                    }
                }
        }
        .accessibilityHidden(true)
    }

    static func color(_ i: Int) -> Color {
        i < 12 ? .green : (i < 17 ? .orange : .red)
    }

    fileprivate static func width(for size: CGSize) -> CGFloat {
        CGFloat(segments) * size.width + CGFloat(segments - 1) * gap
    }
    fileprivate static var spacing: CGFloat { gap }
}

private struct MeterBars: View {
    let model: RadarModel
    let pid: pid_t
    let active: Bool
    let segmentSize: CGSize

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { timeline in
            Canvas { ctx, _ in
                _ = timeline.date
                let lit = (active && !model.mixer.isMuted(pid))
                    ? LevelMeter.litSegments(db: model.mixer.level(for: pid)) : 0
                for i in 0..<LevelMeter.segments {
                    let x = CGFloat(i) * (segmentSize.width + LevelMeter.spacing)
                    let rect = CGRect(x: x, y: 0, width: segmentSize.width, height: segmentSize.height)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5),
                             with: .color(i < lit ? LevelMeter.color(i) : Color.primary.opacity(0.12)))
                }
            }
        }
        .frame(width: LevelMeter.width(for: segmentSize), height: segmentSize.height)
    }
}

/// Slider 0...150 % bound to the mixer. Keeps a local copy because the mixer is not observable.
struct VolumeSlider: View {
    let app: AppRow
    let model: RadarModel
    @State private var volume: Double = 1
    @State private var editing = false

    var body: some View {
        HStack(spacing: 8) {
            VolumeGate(model: model) { allowed in
                Slider(value: $volume, in: 0...1.5) { editing = $0 }
                    .tint(.sound)
                    .controlSize(.small)
                    .disabled(!allowed)
                    .accessibilityLabel("\(app.name) volume")
                    .accessibilityValue("\(Int((volume * 100).rounded())) percent")
            }
            Text("\(Int((volume * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
        .onAppear { volume = Double(model.mixer.volume(for: app.id)) }
        .onChange(of: volume) { _, v in
            // Only write what differs, so a refresh from the mixer never echoes back.
            if abs(model.mixer.volume(for: app.id) - Float(v)) > 0.0005 { model.mixer.setVolume(Float(v), for: app.id) }
        }
        .onScan(model) {
            guard !editing else { return }
            let v = Double(model.mixer.volume(for: app.id))
            if v != volume { volume = v }
        }
    }
}

struct MuteButton: View {
    let app: AppRow
    let model: RadarModel
    @State private var muted = false

    var body: some View {
        VolumeGate(model: model) { allowed in
            Button {
                muted.toggle()
                model.mixer.setMuted(muted, for: app.id)
            } label: {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 18, height: 18)
                    .padding(6)
                    .background(.quaternary, in: .circle)
            }
            .buttonStyle(.plain)
            .disabled(!allowed)
            .accessibilityLabel(muted ? "Unmute \(app.name)" : "Mute \(app.name)")
            .help(muted ? "Unmute" : "Mute")
        }
        .onAppear { muted = model.mixer.isMuted(app.id) }
        .onScan(model) {
            let m = model.mixer.isMuted(app.id)
            if m != muted { muted = m }
        }
    }
}

/// Master volume of the default output device. Same drag rule as `VolumeSlider`: no refresh while dragging.
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
                .controlSize(.small)
                .disabled(!output.canSetVolume)
                .accessibilityLabel("Master volume")
                .accessibilityValue("\(Int((volume * 100).rounded())) percent")
            Text(output.volume == nil ? "n/a" : "\(Int((volume * 100).rounded()))%")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
        .onAppear { volume = Double(output.volume ?? 0) }
        .onChange(of: volume) { _, v in
            if editing || abs(Float(v) - (output.volume ?? 0)) > 0.002 { output.setVolume(Float(v)) }
        }
        .onChange(of: output.volume) { _, v in if !editing { volume = Double(v ?? 0) } }
    }
}

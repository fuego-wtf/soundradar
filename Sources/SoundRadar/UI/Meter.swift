import SwiftUI

/// 20 segments, -60...0 dBFS, green then orange then red. Level -120 (silence or unknown) lights nothing.
struct LevelMeter: View {
    let model: RadarModel
    let pid: pid_t
    var muted = false
    var segmentSize = CGSize(width: 6, height: 10)

    static let segments = 20

    static func litSegments(db: Float) -> Int {
        guard db > -60 else { return 0 }
        let frac = (min(db, 0) + 60) / 60
        return max(1, Int((frac * Float(segments)).rounded(.up)))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { _ in
            let lit = muted ? 0 : Self.litSegments(db: model.mixer.level(for: pid))
            HStack(spacing: 2) {
                ForEach(0..<Self.segments, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(i < lit ? Self.color(i) : Color.primary.opacity(0.12))
                        .frame(width: segmentSize.width, height: segmentSize.height)
                }
            }
        }
        .accessibilityHidden(true)
    }

    static func color(_ i: Int) -> Color {
        i < 12 ? .green : (i < 17 ? .orange : .red)
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
            Slider(value: $volume, in: 0...1.5) { editing = $0 }
                .tint(.sound)
                .controlSize(.small)
                .accessibilityLabel("\(app.name) volume")
                .accessibilityValue("\(Int((volume * 100).rounded())) percent")
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
        .onChange(of: model.lastScan) { _, _ in
            if !editing { volume = Double(model.mixer.volume(for: app.id)) }
        }
    }
}

struct MuteButton: View {
    let app: AppRow
    let model: RadarModel
    @State private var muted = false

    var body: some View {
        Button {
            muted.toggle()
            model.mixer.setMuted(muted, for: app.id)
        } label: {
            Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.glass)
        .controlSize(.small)
        .accessibilityLabel(muted ? "Unmute \(app.name)" : "Mute \(app.name)")
        .help(muted ? "Unmute" : "Mute")
        .onAppear { muted = model.mixer.isMuted(app.id) }
        .onChange(of: model.lastScan) { _, _ in muted = model.mixer.isMuted(app.id) }
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

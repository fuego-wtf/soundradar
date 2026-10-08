import SwiftUI

/// Compact mixer shown from the menu bar. Shares the window's RadarModel.
struct MenuBarMixer: View {
    let model: RadarModel
    let openRadar: () -> Void

    var body: some View {
        let playing = model.playingApps
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Sound Radar").font(.headline)
                Spacer()
                Text(playing.isEmpty ? "Quiet" : "\(playing.count) playing")
                    .font(.caption).foregroundStyle(playing.isEmpty ? Color.secondary : Color.sound)
            }
            HStack(spacing: 8) {
                OutputDeviceChip().font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            MasterVolumeSlider()
            if playing.isEmpty {
                Text("Nothing is playing sound.").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
            } else {
                GlassEffectContainer(spacing: 8) {
                    VStack(spacing: 8) {
                        ForEach(playing) { app in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    AppIconView(app: app, size: 22)
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(app.name).font(.callout.weight(.medium)).lineLimit(1)
                                        Text(app.sourceTitle == app.name ? model.whereIs(app) : app.sourceTitle)
                                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                    MuteButton(app: app, model: model)
                                }
                                VolumeSlider(app: app, model: model)
                            }
                            .padding(10)
                            .glassEffect(.regular, in: .rect(cornerRadius: 14))
                        }
                    }
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Open radar", action: openRadar).buttonStyle(.glass)
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

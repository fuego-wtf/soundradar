import SwiftUI

/// Compact mixer shown from the menu bar. Shares the window's RadarModel.
struct MenuBarMixer: View {
    let model: RadarModel
    let openRadar: () -> Void

    var body: some View {
        let playing = model.playingApps
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Sound Radar").font(.posterSmall(20))
                Spacer()
                Text(playing.isEmpty ? "Quiet" : "\(playing.count) playing")
                    .font(.num(12)).foregroundStyle(playing.isEmpty ? Color.secondary : Color.playing)
            }
            HStack(spacing: 8) {
                OutputDeviceChip().font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            MasterVolumeSlider()
            SoloBanner(model: model)
            PermissionHint(model: model)
            if playing.isEmpty {
                Text("Who's making that noise?").font(.posterSmall(16)).foregroundStyle(.secondary)
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
                                    MuteControl(app: app, model: model)
                                }
                                VolumeSlider(app: app, model: model)
                            }
                            .padding(10)
                            .glassEffect(.regular.tint((app.isPlaying ? Color.playing : Color.justHeard).opacity(0.12)),
                                         in: .rect(cornerRadius: 14))
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

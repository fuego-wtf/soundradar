import SwiftUI

/// Right-hand column: glass channel cards, or the selected source's detail, morphing in place.
struct MixerColumn: View {
    let model: RadarModel
    /// Sounding sources, computed once by the parent.
    let playing: [AppRow]
    @Binding var selected: pid_t?
    @Namespace private var glassNS

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mixer").font(.headline).foregroundStyle(.secondary)
            SoloBanner(model: model)
            if let pid = selected, let app = model.apps.first(where: { $0.id == pid }) {
                GlassEffectContainer(spacing: 12) {
                    SourceDetail(app: app, model: model) {
                        withAnimation(.smooth) { selected = nil }
                    }
                    .glassEffect(.regular.tint(.sound.opacity(0.12)), in: .rect(cornerRadius: 20))
                    .glassEffectID(pid, in: glassNS)
                }
            } else if playing.isEmpty {
                ContentUnavailableView("Nothing is playing", systemImage: "speaker.slash",
                                       description: Text("Sources appear here the moment they make sound."))
                    .frame(maxWidth: .infinity)
            } else {
                PermissionHint(model: model)
                ScrollView {
                    GlassEffectContainer(spacing: 12) {
                        VStack(spacing: 10) {
                            ForEach(playing) { app in
                                ChannelCard(app: app, model: model) {
                                    withAnimation(.smooth) { selected = app.id }
                                }
                                .glassEffect(app.isPlaying ? .regular.tint(.sound.opacity(0.14)) : .regular,
                                             in: .rect(cornerRadius: 18))
                                .glassEffectID(app.id, in: glassNS)
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            Spacer(minLength: 0)
        }
    }
}

struct ChannelCard: View {
    let app: AppRow
    let model: RadarModel
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button(action: open) {
                    HStack(spacing: 10) {
                        AppIconView(app: app, size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.name).font(.callout.weight(.semibold)).lineLimit(1)
                            Text(model.whereLine(app)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(app.name), show details")
                MuteButton(app: app, model: model)
            }
            LevelMeter(model: model, pid: app.id)
            VolumeSlider(app: app, model: model)
        }
        .padding(12)
        .opacity(app.isPlaying ? 1 : 0.7)
    }
}

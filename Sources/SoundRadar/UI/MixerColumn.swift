import SwiftUI

/// Trailing inspector: glass channel cards, or the selected source's detail, morphing in place.
struct MixerColumn: View {
    let model: RadarModel
    /// Sources to list, filtered and computed once by the parent.
    let list: [AppRow]
    let emptyTitle: String
    @Binding var selected: pid_t?
    @Namespace private var glassNS

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Mixer").font(.system(.headline, design: .rounded)).foregroundStyle(.secondary)
                Spacer()
                Text("\(list.count)").font(.num(12)).foregroundStyle(.tertiary)
            }
            SoloBanner(model: model)
            if let pid = selected, let app = model.apps.first(where: { $0.id == pid }) {
                ScrollView {
                    GlassEffectContainer(spacing: 12) {
                        SourceDetail(app: app, model: model) {
                            withAnimation(.snappy(duration: 0.18)) { selected = nil }
                        }
                        .glassEffect(.regular.tint(Color.playing.opacity(0.10)), in: .rect(cornerRadius: 14))
                        .glassEffectID(pid, in: glassNS)
                    }
                }
                .scrollIndicators(.hidden)
            } else if list.isEmpty {
                EmptyPoster(title: emptyTitle, detail: "Sources appear here the moment they make sound.")
                Spacer(minLength: 0)
            } else {
                PermissionHint(model: model)
                ScrollView {
                    GlassEffectContainer(spacing: 12) {
                        LazyVStack(spacing: 10) {
                            ForEach(list) { app in
                                ChannelCard(app: app, model: model, namespace: glassNS) {
                                    withAnimation(.snappy(duration: 0.18)) { selected = app.id }
                                }
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(.top, 4)
    }
}

/// One channel: glass rounded rect, icon, name, where-line, live meter, slider, mute and solo.
/// Focus it (click or Tab), then Left/Right volume, M mute, S solo, Return go to the source.
struct ChannelCard: View {
    let app: AppRow
    let model: RadarModel
    let namespace: Namespace.ID
    let open: () -> Void
    @Environment(SoloCoordinator.self) private var solo
    @State private var volume: Double = 1
    @State private var muted = false
    @FocusState private var focused: Bool
    @State private var hovering = false

    private var tint: Color { app.isPlaying ? .playing : .justHeard }

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
                GlassEffectContainer(spacing: 6) {
                    HStack(spacing: 6) {
                        MuteButton(app: app, model: model, muted: $muted)
                        SoloButton(app: app, model: model)
                    }
                }
            }
            LevelMeter(model: model, pid: app.id)
            VolumeControl(app: app, model: model, volume: $volume)
        }
        .padding(12)
        .opacity(app.isPlaying ? 1 : 0.8)
        .glassEffect(.regular.tint(tint.opacity(app.isPlaying ? 0.14 : 0.08)), in: .rect(cornerRadius: 14))
        .glassEffectID(app.id, in: namespace)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(focused ? 0.7 : (hovering ? 0.18 : 0)), lineWidth: focused ? 1.5 : 1)
                .allowsHitTesting(false)
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .simultaneousGesture(TapGesture().onEnded { focused = true })
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            guard press.modifiers.isEmpty, model.volumeControlEnabled else { return .ignored }
            let step = press.key == .leftArrow ? -0.05 : 0.05
            volume = min(1.5, max(0, ((volume + step) * 100).rounded() / 100))
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "mMsS"), phases: .down) { press in
            guard press.modifiers.isEmpty, model.volumeControlEnabled else { return .ignored }
            if press.characters.lowercased() == "m" { muted.toggle() } else { solo.toggle(app, model: model) }
            return .handled
        }
        .onKeyPress(.return) {
            model.jump(to: app)
            return .handled
        }
    }
}

import SwiftUI

/// Displays and windows to scale. The window that plays glows strongest and carries a glass label chip.
struct RadarMap: View {
    let model: RadarModel
    let select: (pid_t) -> Void

    var body: some View {
        VStack(spacing: 8) {
            map
            OffDesktopChips(model: model)
        }
    }

    private var map: some View {
        GeometryReader { geo in
            let union = model.displays.reduce(CGRect.null) { $0.union($1.frame) }
            if union.isNull {
                Text("No displays").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let pad: CGFloat = 12
                let scale = min((geo.size.width - 2 * pad) / union.width,
                                (geo.size.height - 2 * pad - 24) / union.height)
                let offset = CGPoint(x: (geo.size.width - union.width * scale) / 2,
                                     y: (geo.size.height - 24 - union.height * scale) / 2)
                let map = { (r: CGRect) -> CGRect in
                    CGRect(x: (r.minX - union.minX) * scale + offset.x,
                           y: (r.minY - union.minY) * scale + offset.y,
                           width: r.width * scale, height: r.height * scale)
                }
                let playing = model.playingApps
                let playingPIDs = Set(playing.map(\.id))

                ZStack(alignment: .topLeading) {
                    ForEach(model.displays) { d in
                        let r = map(d.frame)
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.primary.opacity(0.06))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.primary.opacity(d.isMain ? 0.45 : 0.22), lineWidth: 1))
                            .overlay(alignment: .topLeading) {
                                Text(d.isMain ? "\(d.name) (main)" : d.name)
                                    .font(.caption2).foregroundStyle(.secondary).padding(6)
                            }
                            .frame(width: r.width, height: r.height)
                            .offset(x: r.minX, y: r.minY)
                    }
                    ForEach(model.allWindows.reversed().filter { !playingPIDs.contains($0.pid) }) { w in
                        let r = map(w.frame)
                        RoundedRectangle(cornerRadius: 3).stroke(Color.primary.opacity(0.14), lineWidth: 0.5)
                            .frame(width: r.width, height: r.height)
                            .offset(x: r.minX, y: r.minY)
                    }
                    ForEach(playing) { app in
                        let primary = primaryWindow(of: app)
                        ForEach(app.windows) { w in
                            let r = map(w.frame)
                            SoundingWindow(live: app.isPlaying, strongest: w.id == primary?.id)
                                .frame(width: r.width, height: r.height)
                                .offset(x: r.minX, y: r.minY)
                                .onTapGesture { model.jump(to: app) }
                                .accessibilityElement()
                                .accessibilityLabel("\(app.chipTitle), window")
                                .accessibilityAddTraits(.isButton)
                        }
                    }
                    GlassEffectContainer(spacing: 10) {
                        ZStack(alignment: .topLeading) {
                            ForEach(playing) { app in
                                if let w = primaryWindow(of: app) {
                                    let r = map(w.frame)
                                    MapChip(title: app.chipTitle, live: app.isPlaying) { model.jump(to: app) }
                                        .frame(maxWidth: max(120, min(260, geo.size.width * 0.4)))
                                        .position(x: min(max(r.midX, 90), geo.size.width - 90),
                                                  y: min(r.maxY + 16, geo.size.height - 40))
                                }
                            }
                        }
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
        }
        .frame(minHeight: 200)
    }

    /// The located window if it is on screen, else the app's largest visible window.
    private func primaryWindow(of app: AppRow) -> WindowBox? {
        if let n = app.location?.windowNumber, let w = app.windows.first(where: { $0.id == n }) { return w }
        return app.windows.max(by: { $0.frame.area < $1.frame.area })
    }
}

struct SoundingWindow: View {
    let live: Bool
    let strongest: Bool
    @State private var pulse = false

    var body: some View {
        let base = strongest ? (live ? 0.42 : 0.2) : (live ? 0.14 : 0.07)
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Color.sound.opacity(base))
            RoundedRectangle(cornerRadius: 4).stroke(Color.sound.opacity(strongest ? 1 : 0.45), lineWidth: strongest ? 2 : 1)
            if strongest && live {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.sound, lineWidth: 2)
                    .scaleEffect(pulse ? 1.12 : 1)
                    .opacity(pulse ? 0 : 0.9)
            }
        }
        .shadow(color: Color.sound.opacity(strongest ? (live ? 0.7 : 0.3) : 0), radius: 10)
        .onAppear {
            guard strongest && live else { return }
            withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

struct MapChip: View {
    let title: String
    let live: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: live ? "speaker.wave.2.fill" : "speaker.wave.1").foregroundStyle(Color.sound)
                Text(title).lineLimit(1).truncationMode(.tail)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10).padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .glassEffect(.regular.tint(.sound.opacity(0.25)).interactive(), in: .capsule)
        .accessibilityLabel("\(title), go to source")
    }
}

/// Sources that make sound but have no window on this desktop.
struct OffDesktopChips: View {
    let model: RadarModel

    var body: some View {
        let items = model.playingApps.compactMap { app -> (AppRow, String)? in
            guard let loc = app.location else { return nil }
            if let text = loc.space.offDesktopText { return (app, text) }
            return nil
        }
        if !items.isEmpty {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(items, id: \.0.id) { app, text in
                        Button { model.jump(to: app) } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "rectangle.dashed")
                                Text("\(app.name) · \(text)").lineLimit(1)
                            }
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .overlay(Capsule().stroke(Color.sound.opacity(0.7),
                                                  style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        .accessibilityLabel("\(app.name), \(text), go to source")
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

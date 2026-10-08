import SwiftUI

/// Maps global screen coordinates into the map's view space.
struct MapGeometry: Equatable {
    var size: CGSize
    var union: CGRect
    var scale: CGFloat
    var offset: CGPoint

    init?(size: CGSize, displays: [DisplayBox]) {
        let union = displays.reduce(CGRect.null) { $0.union($1.frame) }
        guard !union.isNull, union.width > 0, union.height > 0 else { return nil }
        let pad: CGFloat = 16
        let scale = max(0.01, min((size.width - 2 * pad) / union.width, (size.height - 2 * pad) / union.height))
        self.size = size
        self.union = union
        self.scale = scale
        self.offset = CGPoint(x: (size.width - union.width * scale) / 2,
                              y: (size.height - union.height * scale) / 2)
    }

    func rect(_ r: CGRect) -> CGRect {
        CGRect(x: (r.minX - union.minX) * scale + offset.x, y: (r.minY - union.minY) * scale + offset.y,
               width: r.width * scale, height: r.height * scale)
    }
}

/// Displays and windows to scale. The window that plays glows strongest and carries a glass label chip.
/// Quiet windows and display outlines are one Canvas; only the sounding windows are real views.
struct RadarMap: View {
    let model: RadarModel
    /// Sounding sources, computed once by the parent.
    let playing: [AppRow]
    let select: (pid_t) -> Void

    var body: some View {
        VStack(spacing: 8) {
            map
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.primary.opacity(0.03), in: .rect(cornerRadius: 18))
            OffDesktopChips(model: model, playing: playing)
        }
    }

    private var map: some View {
        GeometryReader { geo in
            if let g = MapGeometry(size: geo.size, displays: model.displays) {
                let playingPIDs = Set(playing.map(\.id))
                ZStack(alignment: .topLeading) {
                    MapBackdrop(geometry: g, displays: model.displays,
                                windows: model.allWindows.filter { !playingPIDs.contains($0.pid) })
                        .equatable()
                    SoundingLayer(model: model, playing: playing, displays: model.displays, geometry: g)
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            } else {
                Text("No displays").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minHeight: 220)
    }
}

/// Display outlines, their names and every quiet window, drawn in a single Canvas.
struct MapBackdrop: View, Equatable {
    let geometry: MapGeometry
    let displays: [DisplayBox]
    let windows: [WindowBox]

    var body: some View {
        Canvas { ctx, _ in
            let ink = Color.primary
            for d in displays {
                let r = geometry.rect(d.frame)
                let shape = Path(roundedRect: r, cornerRadius: 8)
                ctx.fill(shape, with: .color(ink.opacity(0.06)))
                ctx.stroke(shape, with: .color(ink.opacity(d.isMain ? 0.45 : 0.22)), lineWidth: 1)
                let label = ctx.resolve(Text(d.isMain ? "\(d.name) (main)" : d.name)
                    .font(.caption2).foregroundStyle(.secondary))
                ctx.draw(label, at: CGPoint(x: r.minX + 6, y: r.minY + 6), anchor: .topLeading)
            }
            for w in windows.reversed() {
                ctx.stroke(Path(roundedRect: geometry.rect(w.frame), cornerRadius: 3),
                           with: .color(ink.opacity(0.14)), lineWidth: 0.5)
            }
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// The handful of sounding windows (glow, pulse, tap target) and their glass chips.
struct SoundingLayer: View {
    let model: RadarModel
    let playing: [AppRow]
    let displays: [DisplayBox]
    let geometry: MapGeometry

    var body: some View {
        let size = geometry.size
        ZStack(alignment: .topLeading) {
            ForEach(playing) { app in
                let primary = primaryWindow(of: app)
                ForEach(app.windows) { w in
                    let r = geometry.rect(w.frame)
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
                            let r = geometry.rect(w.frame)
                            let chipW = max(140, min(300, size.width * 0.45))
                            let halfW = min(chipW, 220) / 2 + 4   // chip is fixedSize; assume up to ~220pt wide
                            let small = r.width < 200 || r.height < 120
                            let cy = small ? r.maxY + 6 + 22 : r.maxY - 26
                            MapChip(title: app.chipTitle, subtitle: app.chipSubtitle(display: displayName(for: w)),
                                    live: app.isPlaying) { model.jump(to: app) }
                                .frame(maxWidth: chipW)
                                .position(x: min(max(r.midX, halfW), max(halfW, size.width - halfW)),
                                          y: min(max(cy, 30), size.height - 30))
                        }
                    }
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
            }
        }
    }

    private func displayName(for w: WindowBox) -> String? {
        let c = CGPoint(x: w.frame.midX, y: w.frame.midY)
        return (displays.first { $0.frame.contains(c) }
                ?? displays.min { $0.frame.distance(to: c) < $1.frame.distance(to: c) })?.name
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

    var body: some View {
        let base = strongest ? (live ? 0.42 : 0.2) : (live ? 0.14 : 0.07)
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Color.sound.opacity(base))
            RoundedRectangle(cornerRadius: 4).stroke(Color.sound.opacity(strongest ? 1 : 0.45), lineWidth: strongest ? 2 : 1)
            if strongest && live { PulseRing() }
        }
        .shadow(color: Color.sound.opacity(strongest ? (live ? 0.7 : 0.3) : 0), radius: 10)
    }
}

/// Expanding ring. Its animation state lives here, so the repeating animation touches no other view.
struct PulseRing: View {
    @State private var pulse = false

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .stroke(Color.sound, lineWidth: 2)
            .scaleEffect(pulse ? 1.12 : 1)
            .opacity(pulse ? 0 : 0.9)
            .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: pulse)
            .onAppear { pulse = true }
            .allowsHitTesting(false)
    }
}

struct MapChip: View {
    let title: String
    var subtitle: String = ""
    let live: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: live ? "speaker.wave.2.fill" : "speaker.wave.1").foregroundStyle(Color.sound)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .glassEffect(.regular.tint(.sound.opacity(0.25)).interactive(), in: .capsule)
        .accessibilityLabel("\(title), \(subtitle), go to source")
    }
}

/// Sources that make sound but have no window on this desktop.
struct OffDesktopChips: View {
    let model: RadarModel
    let playing: [AppRow]

    var body: some View {
        let items = playing.compactMap { app -> (AppRow, String)? in
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
                                Text("\(app.chipTitle) · \(text)").lineLimit(1).truncationMode(.middle)
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

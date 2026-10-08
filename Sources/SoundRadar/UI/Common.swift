import AppKit
import CoreAudio
import SwiftUI

// Shared helpers for the interface layer.

extension AppRow {
    /// Most specific human name of what is making the sound: tab, else window, else the app.
    var sourceTitle: String { location?.tabTitle ?? location?.windowTitle ?? name }

    /// "App · tab/window title", cut in the middle at about 40 characters.
    var chipTitle: String {
        let t = sourceTitle
        return t == name ? name : "\(name) · \(t.middleTruncated(40))"
    }

    /// Display name and desktop status for the second chip line.
    func chipSubtitle(display: String?) -> String {
        [display, location?.space.detailText].compactMap { $0 }.joined(separator: " · ")
    }

    var isSounding: Bool { isPlaying || recentlyPlayed }
}

extension SpaceStatus {
    /// Words for a source that is not on the current desktop; nil when it is visible or has no window.
    var offDesktopText: String? {
        switch self {
        case .otherDesktop: "on another desktop"
        case .minimized: "minimized"
        case .hidden: "hidden"
        case .thisDesktop, .noWindow: nil
        }
    }

    var detailText: String {
        switch self {
        case .thisDesktop: "This desktop"
        case .otherDesktop: "Another desktop"
        case .minimized: "Minimized"
        case .hidden: "Hidden"
        case .noWindow: "No window"
        }
    }
}

extension RadarModel {
    /// One line under a source name: the tab or window, then where it sits.
    func whereLine(_ app: AppRow) -> String {
        if let off = app.location?.space.offDesktopText {
            return [app.location?.tabTitle ?? app.location?.windowTitle, off]
                .compactMap { $0 }.joined(separator: " · ")
        }
        if let title = app.location?.tabTitle ?? app.location?.windowTitle {
            return "\(title) · \(whereIs(app))"
        }
        return whereIs(app)
    }
}

struct AppIconView: View {
    let app: AppRow
    var size: CGFloat = 28

    var body: some View {
        Group {
            if let icon = app.icon {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: "app.dashed").resizable().scaledToFit().foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Output device chip: name and an icon for how it is connected, live from `OutputDevice`.
struct OutputDeviceChip: View {
    private let output = OutputDevice.shared

    var body: some View {
        Label(output.name ?? "No output", systemImage: output.transport.symbol)
            .font(.callout)
            .lineLimit(1)
            .help("\(output.transport.label) output")
            .accessibilityLabel("Output device \(output.name ?? "none"), \(output.transport.label)")
    }
}

extension RadarModel {
    /// True once the system lets Sound Radar change per-app volume. Not observable: read it through
    /// `VolumeGate` (or `onScan`) so only that leaf refreshes on a scan tick.
    var volumeControlEnabled: Bool { mixer.permission == .granted }
}

/// Zero-size leaf whose body is the only one that reads `model.lastScan`; a scan tick re-evaluates
/// this and nothing else, then runs `action`.
struct ScanSync: View {
    let model: RadarModel
    let action: () -> Void

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onChange(of: model.lastScan) { _, _ in action() }
            .accessibilityHidden(true)
    }
}

extension View {
    /// Runs `action` on every model scan without making this view depend on `lastScan`.
    func onScan(_ model: RadarModel, perform action: @escaping () -> Void) -> some View {
        background(ScanSync(model: model, action: action))
    }
}

/// Hands its content whether volume control is allowed, refreshing only itself on a scan.
struct VolumeGate<Content: View>: View {
    let model: RadarModel
    @ViewBuilder let content: (Bool) -> Content
    @State private var allowed: Bool

    init(model: RadarModel, @ViewBuilder content: @escaping (Bool) -> Content) {
        self.model = model
        self.content = content
        _allowed = State(initialValue: model.volumeControlEnabled)
    }

    var body: some View {
        content(allowed).onScan(model) {
            let now = model.volumeControlEnabled
            if now != allowed { allowed = now }
        }
    }
}

/// One-line hint shown in place of working volume controls until capture is allowed. Flat, so it can
/// sit inside glass cards without nesting a second glass layer.
struct PermissionHint: View {
    let model: RadarModel

    var body: some View {
        VolumeGate(model: model) { allowed in
            if !allowed {
                Button { model.mixer.requestPermission() } label: {
                    Label("Turn on volume control", systemImage: "lock.open")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .glassEffect(.regular.tint(Color.needsPermission.opacity(0.35)).interactive(), in: .capsule)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Turn on volume control")
            }
        }
    }
}

/// "Solo: App  [End solo]" capsule, visible while solo is active.
struct SoloBanner: View {
    @Environment(SoloCoordinator.self) private var solo
    let model: RadarModel

    var body: some View {
        if let name = solo.soloName {
            HStack(spacing: 8) {
                Image(systemName: "headphones").foregroundStyle(Color.playing)
                Text("Solo: \(name)").font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Button("End solo") { solo.restore(model) }
                    .buttonStyle(.glass).controlSize(.small)
                    .accessibilityLabel("End solo")
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            .glassEffect(.regular.tint(Color.playing.opacity(0.2)), in: .capsule)
        }
    }
}

/// Solo: mute every other playing app, including ones that start later, and restore them when
/// solo ends or the soloed app has been silent for `silenceLimit` seconds.
@Observable
@MainActor
final class SoloCoordinator {
    nonisolated static let silenceLimit: TimeInterval = 5

    private(set) var soloed: pid_t?
    private(set) var soloName: String?
    private var previous: [pid_t: Bool] = [:]
    private var lastSounding = Date()
    private var watcher: Task<Void, Never>?

    func toggle(_ app: AppRow, model: RadarModel) {
        let wasSoloed = soloed == app.id
        restore(model)
        if wasSoloed || model.mixer.permission != .granted { return }
        soloed = app.id
        soloName = app.name
        lastSounding = Date()
        tick(model)
        watcher = Task { [weak self, weak model] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, let model else { return }
                self.tick(model)
            }
        }
    }

    /// Mute newly playing apps; end solo once the soloed app has stayed silent long enough.
    func tick(_ model: RadarModel, now: Date = Date()) {
        guard let soloed else { return }
        let playing = model.playingApps
        for row in playing where row.id != soloed && previous[row.id] == nil {
            previous[row.id] = model.mixer.isMuted(row.id)
            model.mixer.setMuted(true, for: row.id)
        }
        if playing.contains(where: { $0.id == soloed }) {
            lastSounding = now
        } else if now.timeIntervalSince(lastSounding) >= Self.silenceLimit {
            restore(model)
        }
    }

    func restore(_ model: RadarModel) {
        watcher?.cancel()
        watcher = nil
        for (pid, wasMuted) in previous { model.mixer.setMuted(wasMuted, for: pid) }
        previous = [:]
        soloed = nil
        soloName = nil
    }
}

// MARK: - Palette: colour comes only from states

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
    /// Playing.
    static let playing = Color(hex: 0x28C840)
    /// Just heard.
    static let justHeard = Color(hex: 0xFEBC2E)
    /// Needs permission.
    static let needsPermission = Color(hex: 0x6366F1)
    /// Muted or failed.
    static let muted = Color(hex: 0xFF5F57)
}

extension Font {
    /// Numbers (percent, dB, counts): SF Rounded with monospaced digits.
    static func num(_ size: CGFloat = 12, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
    /// Poster line: New York serif italic.
    static let poster = Font.system(size: 28, design: .serif).italic()
    static func posterSmall(_ size: CGFloat = 18) -> Font { .system(size: size, design: .serif).italic() }
}

/// Rounds a rect onto the pixel grid so a 1-pixel stroke is crisp (edges land on pixel centres).
func pixelAligned(_ r: CGRect, scale: CGFloat) -> CGRect {
    let s = max(1, scale)
    let x0 = (r.minX * s).rounded() / s + 0.5 / s, y0 = (r.minY * s).rounded() / s + 0.5 / s
    let x1 = (r.maxX * s).rounded() / s - 0.5 / s, y1 = (r.maxY * s).rounded() / s - 0.5 / s
    return CGRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
}

// MARK: - Stage behind the glass

/// Near-black stage with one soft spotlight (dark), paper (light). Glass refracts this.
struct Stage: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        ZStack {
            Color(hex: dark ? 0x0B0B0B : 0xF3EBDD)
            RadialGradient(colors: [Color.white.opacity(dark ? 0.12 : 0.55), .clear],
                           center: UnitPoint(x: 0.5, y: 0.22), startRadius: 0, endRadius: 560)
        }
        .ignoresSafeArea()
    }
}

/// Row hover feedback in 0.12 s.
struct HoverHighlight: ViewModifier {
    var radius: CGFloat = 10
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.08 : 0)))
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverHighlight(radius: CGFloat = 10) -> some View { modifier(HoverHighlight(radius: radius)) }
}

/// The mark; while `active` its wave count runs 0 to 2. Only this leaf redraws.
struct PulsingMark: View {
    let active: Bool
    var color: Color = .primary

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.3, paused: !active)) { tl in
            let n = active ? Int(tl.date.timeIntervalSinceReferenceDate / 0.3) % 3 : 0
            SoundRadarMark(waves: n, monochrome: active ? nil : color)
        }
    }
}

/// Big mark (no waves) and a serif italic line, for empty states.
struct EmptyPoster: View {
    let title: String
    var detail: String?

    var body: some View {
        VStack(spacing: 10) {
            SoundRadarMark(waves: 0, monochrome: .secondary).frame(width: 72, height: 72)
            Text(title).font(.posterSmall(22)).multilineTextAlignment(.center)
            if let detail { Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center) }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 28).padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
    }
}

extension String {
    func middleTruncated(_ limit: Int) -> String {
        guard count > limit, limit > 2 else { return self }
        let head = (limit - 1 + 1) / 2, tail = limit - 1 - head
        return String(prefix(head)) + "…" + String(suffix(tail))
    }
}

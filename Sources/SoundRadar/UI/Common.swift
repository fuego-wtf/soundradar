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
    /// True once the system lets Sound Radar change per-app volume. Reads `lastScan` so views refresh.
    var volumeControlEnabled: Bool { _ = lastScan; return mixer.permission == .granted }
}

/// One-line glass hint shown in place of working volume controls until capture is allowed.
struct PermissionHint: View {
    let model: RadarModel

    var body: some View {
        if !model.volumeControlEnabled {
            Button { model.mixer.requestPermission() } label: {
                Label("Turn on volume control", systemImage: "lock.open")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10).padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
            .accessibilityLabel("Turn on volume control")
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
                Image(systemName: "headphones").foregroundStyle(Color.sound)
                Text("Solo: \(name)").font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Button("End solo") { solo.restore(model) }
                    .buttonStyle(.glass).controlSize(.small)
                    .accessibilityLabel("End solo")
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            .glassEffect(.regular.tint(.sound.opacity(0.2)), in: .capsule)
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

extension Color {
    static let sound = Color.orange
}

extension String {
    func middleTruncated(_ limit: Int) -> String {
        guard count > limit, limit > 2 else { return self }
        let head = (limit - 1 + 1) / 2, tail = limit - 1 - head
        return String(prefix(head)) + "…" + String(suffix(tail))
    }
}

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

/// Solo: mute every other playing app, remembering their state so it can be restored.
@Observable
@MainActor
final class SoloCoordinator {
    private(set) var soloed: pid_t?
    private var previous: [pid_t: Bool] = [:]

    func toggle(_ app: pid_t, model: RadarModel) {
        let wasSoloed = soloed == app
        restore(model)
        if wasSoloed { return }
        previous = [:]
        for row in model.playingApps {
            previous[row.id] = model.mixer.isMuted(row.id)
            model.mixer.setMuted(row.id != app, for: row.id)
        }
        soloed = app
    }

    func restore(_ model: RadarModel) {
        for (pid, wasMuted) in previous { model.mixer.setMuted(wasMuted, for: pid) }
        previous = [:]
        soloed = nil
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

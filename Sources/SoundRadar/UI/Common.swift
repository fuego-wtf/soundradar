import AppKit
import CoreAudio
import SwiftUI

// Shared helpers for the interface layer.

extension AppRow {
    /// Most specific human name of what is making the sound: tab, else window, else the app.
    var sourceTitle: String { location?.tabTitle ?? location?.windowTitle ?? name }

    /// "App · tab/window title" for map chips.
    var chipTitle: String {
        let t = sourceTitle
        return t == name ? name : "\(name) · \(t)"
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

enum OutputDevice {
    /// Name of the current default output device, read from Core Audio.
    static func currentName() -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var nsize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &nameAddr, 0, nil, &nsize, &name) == noErr,
              let name else { return nil }
        return name.takeRetainedValue() as String
    }
}

/// Output device chip; re-reads the device once a second so a switch shows up.
struct OutputDeviceChip: View {
    @State private var name = OutputDevice.currentName()

    var body: some View {
        Label(name ?? "No output", systemImage: "hifispeaker.fill")
            .font(.callout)
            .lineLimit(1)
            .task {
                while !Task.isCancelled {
                    name = OutputDevice.currentName()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            .accessibilityLabel("Output device \(name ?? "none")")
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

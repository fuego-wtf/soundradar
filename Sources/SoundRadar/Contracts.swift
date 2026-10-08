import CoreAudio
import Foundation

// Seams between the parts of Sound Radar. Each lane implements one side;
// the Null* types keep the app building and running until a real one lands.

// MARK: - Per-app volume and loudness

/// One app that currently has audio output running, with the Core Audio process
/// objects (the app itself and its helpers) that carry its sound.
struct AudioSource: Hashable, Sendable {
    let app: pid_t
    let processObjects: [AudioObjectID]
}

enum CapturePermission: Sendable { case unknown, granted, denied }

@MainActor
protocol AudioMixing: AnyObject {
    var permission: CapturePermission { get }
    func requestPermission()
    /// 0...1.5, 1 = unchanged.
    func volume(for app: pid_t) -> Float
    func isMuted(_ app: pid_t) -> Bool
    func setVolume(_ volume: Float, for app: pid_t)
    func setMuted(_ muted: Bool, for app: pid_t)
    /// Recent loudness in dBFS; -120 means silence or unknown.
    func level(for app: pid_t) -> Float
    /// Called on every scan with the apps whose output is running now.
    func sync(_ sources: [AudioSource])
}

@MainActor
final class NullMixer: AudioMixing {
    private var volumes: [pid_t: Float] = [:]
    private var muted: Set<pid_t> = []
    var permission: CapturePermission { .unknown }
    func requestPermission() {}
    func volume(for app: pid_t) -> Float { volumes[app] ?? 1 }
    func isMuted(_ app: pid_t) -> Bool { muted.contains(app) }
    func setVolume(_ volume: Float, for app: pid_t) { volumes[app] = volume }
    func setMuted(_ m: Bool, for app: pid_t) { if m { muted.insert(app) } else { muted.remove(app) } }
    func level(for app: pid_t) -> Float { -120 }
    func sync(_ sources: [AudioSource]) {}
}

// MARK: - Exact location of a sound

enum SpaceStatus: Hashable, Sendable {
    case thisDesktop, otherDesktop, minimized, hidden, noWindow
}

struct SourceLocation: Hashable, Sendable {
    var windowTitle: String?
    var tabTitle: String?
    var tabURL: String?
    var space: SpaceStatus = .noWindow
    /// Window number in CGWindowList terms, when known, so the map can highlight that one window.
    var windowNumber: UInt32?
}

@MainActor
protocol SoundLocating: AnyObject {
    var accessibilityGranted: Bool { get }
    func requestAccessibility()
    func locate(app: pid_t, bundleID: String?, helperPIDs: [pid_t]) async -> SourceLocation
    /// Brings the exact window (and browser tab, when known) to the front.
    func jump(app: pid_t, bundleID: String?, to location: SourceLocation)
}

@MainActor
final class NullLocator: SoundLocating {
    var accessibilityGranted: Bool { false }
    func requestAccessibility() {}
    func locate(app: pid_t, bundleID: String?, helperPIDs: [pid_t]) async -> SourceLocation { SourceLocation() }
    func jump(app: pid_t, bundleID: String?, to location: SourceLocation) {}
}

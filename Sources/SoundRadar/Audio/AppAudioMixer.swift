import AppKit
import CoreAudio
import Foundation
import os

/// Per-app metering and volume through Core Audio process taps (macOS 14.2+).
/// One channel per app: a stereo mixdown tap over all of its process objects.
/// Unmuted meter-only tap at volume 1; muted tap plus re-render when volume != 1 or muted.
@MainActor
final class AppAudioMixer: AudioMixing {
    static let requestedKey = "capture.requested"
    nonisolated static let graceSeconds: TimeInterval = 5
    nonisolated static let retryBackoff: TimeInterval = 3
    nonisolated static let watchdogSeconds: TimeInterval = 1

    private(set) var permission: CapturePermission = .unknown

    private let defaults: UserDefaults
    private var volumes: [pid_t: Float] = [:]
    private var muted: Set<pid_t> = []
    private var channels: [pid_t: TapChannel] = [:]
    private var lastActive: [pid_t: TimeInterval] = [:]
    private var retryAfter: [pid_t: TimeInterval] = [:]
    private var stallProgress: [pid_t: MixerMath.StallProgress] = [:]
    private var latest: [pid_t: Set<AudioObjectID>] = [:]
    private var smoothed: [pid_t: (value: Float, at: TimeInterval)] = [:]
    private var probeInFlight = false
    private var listener: AudioObjectPropertyListenerBlock?
    private var terminationObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        installDeviceListener()
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
        if defaults.bool(forKey: Self.requestedKey) { requestPermission() }
    }

    // MARK: AudioMixing

    func requestPermission() {
        defaults.set(true, forKey: Self.requestedKey)
        guard permission != .granted, !probeInFlight else { return }
        if permission == .denied { openPrivacySettings() }
        guard let uid = DefaultOutput.uid() else { return }
        probeInFlight = true
        // Tap creation may block while macOS shows the prompt, so keep it off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let probe = TapChannel(kind: .permissionProbe, processing: false, gain: 1)
            var failure: MixerError?
            do { try probe.start(outputUID: uid) } catch { failure = error as? MixerError }
            var gotCallback = false
            if failure == nil {
                let deadline = Date().addingTimeInterval(2)
                while Date() < deadline {
                    if probe.state.callbackCount > 0 { gotCallback = true; break }
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
            probe.stop()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finishProbe(failure: failure, gotCallback: gotCallback) }
            }
        }
    }

    /// Opens System Settings at Privacy > System Audio Recording (falls back to Privacy).
    func openPrivacySettings() {
        let urls = ["x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture",
                    "x-apple.systempreferences:com.apple.preference.security?Privacy"]
        for u in urls {
            if let url = URL(string: u), NSWorkspace.shared.open(url) { return }
        }
    }

    func volume(for app: pid_t) -> Float { volumes[app] ?? 1 }
    func isMuted(_ app: pid_t) -> Bool { muted.contains(app) }

    func setVolume(_ volume: Float, for app: pid_t) {
        volumes[app] = MixerMath.clampVolume(volume)
        applySettings(app)
    }

    func setMuted(_ m: Bool, for app: pid_t) {
        if m { muted.insert(app) } else { muted.remove(app) }
        applySettings(app)
    }

    func level(for app: pid_t) -> Float {
        guard let ch = channels[app] else { smoothed[app] = nil; return MixerMath.silenceDB }
        let now = ProcessInfo.processInfo.systemUptime
        let raw = ch.state.level
        let prev = smoothed[app] ?? (raw, now)
        let next = MixerMath.smoothLevel(current: prev.value, target: raw, dt: Float(now - prev.at))
        smoothed[app] = (next, now)
        return next
    }

    func sync(_ sources: [AudioSource]) {
        let now = ProcessInfo.processInfo.systemUptime
        var wanted: [pid_t: Set<AudioObjectID>] = [:]
        for s in sources where !s.processObjects.isEmpty {
            wanted[s.app, default: []].formUnion(s.processObjects)
        }
        latest = wanted
        for pid in wanted.keys { lastActive[pid] = now }
        guard permission == .granted else { return }

        checkWatchdog(now: now)
        // Processing channels of live processes keep their tap even when the app goes quiet.
        let keepAlive = Set(channels.filter { $0.value.processing && Self.isAlive($0.key) }.keys)
        let plan = MixerMath.planChannels(
            current: channels.mapValues { $0.objects }, sources: wanted,
            lastActive: lastActive, now: now, grace: Self.graceSeconds, keepAlive: keepAlive)

        for pid in plan.teardown {
            destroyChannel(pid)
            lastActive[pid] = nil
            retryAfter[pid] = nil
            processingPids.remove(pid)
            if kill(pid, 0) == -1 && errno == ESRCH { volumes[pid] = nil; muted.remove(pid) }
        }
        for pid in plan.rebuild {
            destroyChannel(pid)
            if let objs = wanted[pid] { createChannel(pid, objects: objs, now: now) }
        }
        for pid in plan.create {
            if let wait = retryAfter[pid], now < wait { continue }
            if let objs = wanted[pid] { createChannel(pid, objects: objs, now: now) }
        }
    }

    // MARK: Channels

    /// Apps whose channel has entered processing mode; they stay there until torn down.
    private var processingPids = Set<pid_t>()

    nonisolated static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// The stored volume is a slider position; the channel gets the tapered gain.
    private func gain(for pid: pid_t) -> Float {
        MixerMath.targetGain(volume: MixerMath.sliderToGain(volume(for: pid)), muted: isMuted(pid))
    }

    private func createChannel(_ pid: pid_t, objects: Set<AudioObjectID>, now: TimeInterval) {
        guard let uid = DefaultOutput.uid() else { retryAfter[pid] = now + Self.retryBackoff; return }
        let processing = MixerMath.keepsProcessing(wasProcessing: processingPids.contains(pid),
                                                    volume: volume(for: pid), muted: isMuted(pid),
                                                    permissionGranted: permission == .granted)
        if processing { processingPids.insert(pid) }
        let ch = TapChannel(kind: .processes(objects.sorted()), processing: processing, gain: gain(for: pid))
        do {
            try ch.start(outputUID: uid)
            channels[pid] = ch
            stallProgress[pid] = MixerMath.StallProgress(count: 0, at: ch.startedAt)
            retryAfter[pid] = nil
        } catch {
            // Never leave a half-built (possibly muting) tap behind: stop() unwinds everything.
            ch.stop()
            retryAfter[pid] = now + Self.retryBackoff
            mixerLog.error("channel for pid \(pid) not created: \(String(describing: error))")
        }
    }

    private func destroyChannel(_ pid: pid_t) {
        channels.removeValue(forKey: pid)?.stop()
        smoothed[pid] = nil
        stallProgress[pid] = nil
    }

    private func applySettings(_ pid: pid_t) {
        guard let ch = channels[pid] else { return }
        let needs = MixerMath.keepsProcessing(wasProcessing: ch.processing, volume: volume(for: pid), muted: isMuted(pid),
                                                permissionGranted: permission == .granted)
        if needs != ch.processing {
            let objs = ch.objects
            destroyChannel(pid)
            createChannel(pid, objects: objs, now: ProcessInfo.processInfo.systemUptime)
        } else {
            ch.state.setTarget(gain(for: pid))
        }
    }

    /// A muted tap whose render callback stops advancing would silence the app: drop it so the
    /// app's own sound returns, and retry after a backoff.
    private func checkWatchdog(now: TimeInterval) {
        for (pid, ch) in channels {
            let seen = stallProgress[pid] ?? MixerMath.StallProgress(count: 0, at: ch.startedAt)
            let step = MixerMath.stallStep(processing: ch.processing, count: ch.state.callbackCount,
                                           progress: seen, now: now, threshold: Self.watchdogSeconds)
            stallProgress[pid] = step.progress
            if step.stalled {
                mixerLog.error("pid \(pid): muted tap stalled, destroying so sound is restored")
                destroyChannel(pid)
                retryAfter[pid] = now + 10
            }
        }
    }

    // MARK: Device change, permission, quit

    private func installDeviceListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.rebuildAll() }
        }
        listener = block
        var addr = DefaultOutput.address
        let st = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
        if st != noErr { mixerLog.error("default output listener: \(st)") }
    }

    private func rebuildAll() {
        let now = ProcessInfo.processInfo.systemUptime
        let old = channels.mapValues { $0.objects }
        for pid in old.keys { destroyChannel(pid) }
        guard permission == .granted else { return }
        for (pid, objs) in old { createChannel(pid, objects: objs, now: now) }
    }

    private func finishProbe(failure: MixerError?, gotCallback: Bool) {
        probeInFlight = false
        if let failure {
            mixerLog.error("permission probe: \(failure.description)")
            permission = .denied
        } else if gotCallback {
            permission = .granted
            sync(latest.map { AudioSource(app: $0.key, processObjects: Array($0.value)) })
        } else {
            mixerLog.error("permission probe: tap created but no audio callback arrived")
        }
    }

    private func shutdown() {
        for pid in Array(channels.keys) { destroyChannel(pid) }
        if let listener {
            var addr = DefaultOutput.address
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, listener)
        }
        listener = nil
    }
}

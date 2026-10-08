import AppKit
import CoreAudio

/// What the model needs to know about a running app; a Sendable snapshot of NSRunningApplication.
struct AppInfo: Sendable, Equatable {
    let pid: pid_t
    let name: String
    let bundleID: String?
    let isRegular: Bool
}

/// One audio client with the app it belongs to (nil when no app owns it).
struct OwnedClient: Sendable {
    let client: AudioClient
    let ownerPID: pid_t?
}

struct ScanResult: Sendable {
    let clients: [OwnedClient]
    let windows: [WindowBox]
}

/// Runs the Core Audio and window scans off the main thread on a fixed cadence.
final class ScanEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "soundradar.scan", qos: .utility)
    private var timer: DispatchSourceTimer?
    // Everything below is touched only on `queue`.
    private lazy var audio = AudioScanCache(queue: queue)
    private var apps: [pid_t: AppInfo] = [:]
    private var owners: [pid_t: pid_t?] = [:]
    private let selfPID = ProcessInfo.processInfo.processIdentifier

    /// New app set: owner lookups are redone lazily.
    func update(apps: [pid_t: AppInfo]) {
        queue.async { self.apps = apps; self.owners.removeAll(keepingCapacity: true) }
    }

    func start(every interval: TimeInterval, deliver: @escaping @MainActor @Sendable (ScanResult) -> Void) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let result = self.scan()
            Task { @MainActor in deliver(result) }
        }
        timer = t
        t.resume()
    }

    private func scan() -> ScanResult {
        let clients = audio.scan().filter { $0.pid != selfPID }   // our own taps are not a source
        let owned = clients.map { c -> OwnedClient in
            let owner: pid_t?
            if let cached = owners[c.pid] { owner = cached } else {
                owner = ProcessTree.owningPID(for: c.pid, apps: apps)
                owners[c.pid] = owner
            }
            return OwnedClient(client: c, ownerPID: owner)
        }
        return ScanResult(clients: owned, windows: WindowScanner.windows())
    }
}

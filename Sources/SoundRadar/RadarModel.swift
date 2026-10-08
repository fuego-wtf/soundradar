import AppKit
import CoreAudio
import Observation

struct AppRow: Identifiable, Equatable {
    let id: pid_t
    let name: String
    let bundleID: String?
    let icon: NSImage?
    let isRegular: Bool
    var isPlaying = false
    var isRecording = false
    var outputDevices: Set<String> = []
    var inputDevices: Set<String> = []
    var helpers: Set<String> = []      // audio-running helper processes attributed to this app
    var helperPIDs: [pid_t] = []
    var audioObjects: [AudioObjectID] = []   // Core Audio process objects carrying this app's output
    var location: SourceLocation?
    var lastPlayed: Date?
    var windows: [WindowBox] = []
    /// Snapshot of `recentlyPlayed` at scan time, so rows compare equal between scans.
    var recent = false

    var recentlyPlayed: Bool {
        guard let lastPlayed else { return false }
        return Date().timeIntervalSince(lastPlayed) < RadarModel.holdSeconds
    }

    /// Icons are cached per pid and never change, so equality ignores them.
    static func == (a: AppRow, b: AppRow) -> Bool {
        a.id == b.id && a.name == b.name && a.isPlaying == b.isPlaying && a.isRecording == b.isRecording
            && a.recent == b.recent && a.outputDevices == b.outputDevices && a.inputDevices == b.inputDevices
            && a.helpers == b.helpers && a.audioObjects == b.audioObjects && a.location == b.location
            && a.windows == b.windows && a.isRegular == b.isRegular
    }
}

@Observable
@MainActor
final class RadarModel {
    nonisolated static let holdSeconds: TimeInterval = 4   // keep short blips (alert sounds) visible
    nonisolated static let scanInterval: TimeInterval = 0.3

    // Assigned only when they change, so a scan that finds nothing new redraws nothing.
    private(set) var apps: [AppRow] = []
    private(set) var playingApps: [AppRow] = []
    private(set) var visibleApps: [AppRow] = []
    private(set) var orphans: [AudioClient] = []            // audio processes with no GUI owner
    private(set) var displays: [DisplayBox] = []
    private(set) var allWindows: [WindowBox] = []
    var showBackgroundApps = false { didSet { publish(apps) } }
    /// Ticks on every scan; read only inside small leaf views.
    private(set) var lastScan = Date()
    private(set) var history: [SoundEvent] = []            // newest first, one entry per sound burst

    let mixer: AudioMixing
    let locator: SoundLocating
    private var locations: [pid_t: SourceLocation] = [:]
    private var lastLocate = Date.distantPast
    private var lastPlayed: [pid_t: Date] = [:]

    private let engine = ScanEngine()
    private var appInfos: [pid_t: AppInfo] = [:]
    private var icons: [pid_t: NSImage] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(mixer: AudioMixing, locator: SoundLocating) {
        self.mixer = mixer
        self.locator = locator
        reloadApps()
        displays = WindowScanner.displays()
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reloadApps() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let d = WindowScanner.displays()
                if d != self.displays { self.displays = d }
            }
        })
        engine.start(every: Self.scanInterval) { [weak self] result in self?.apply(result) }
    }

    /// Running apps change rarely; rebuild their snapshot on launch, quit and activation only.
    private func reloadApps() {
        var infos: [pid_t: AppInfo] = [:]
        for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier
            infos[pid] = AppInfo(pid: pid, name: app.localizedName ?? app.bundleIdentifier ?? "pid \(pid)",
                                 bundleID: app.bundleIdentifier, isRegular: app.activationPolicy == .regular)
        }
        guard infos != appInfos else { return }
        icons = icons.filter { infos[$0.key] != nil }
        appInfos = infos
        engine.update(apps: infos)
    }

    private func icon(for pid: pid_t) -> NSImage? {
        if let i = icons[pid] { return i }
        let i = NSRunningApplication(processIdentifier: pid)?.icon
        icons[pid] = i
        return i
    }

    private func apply(_ result: ScanResult) {
        let now = Date()
        var rows: [pid_t: AppRow] = [:]
        rows.reserveCapacity(appInfos.count)
        for (pid, info) in appInfos {
            rows[pid] = AppRow(id: pid, name: info.name, bundleID: info.bundleID, icon: nil, isRegular: info.isRegular)
        }

        var unowned: [AudioClient] = []
        for owned in result.clients {
            let client = owned.client
            guard let ownerPID = owned.ownerPID, var row = rows[ownerPID] else {
                unowned.append(client)
                continue
            }
            if client.isRunningOutput {
                row.isPlaying = true
                row.audioObjects.append(client.objectID)
                row.outputDevices.formUnion(client.outputDevices)
                lastPlayed[row.id] = now
            }
            if client.isRunningInput {
                row.isRecording = true
                row.inputDevices.formUnion(client.inputDevices)
            }
            if client.pid != ownerPID {
                row.helpers.insert(client.executableName)
                row.helperPIDs.append(client.pid)
            }
            rows[ownerPID] = row
        }

        let windowsByPID = Dictionary(grouping: result.windows, by: \.pid)
        lastPlayed = lastPlayed.filter { rows[$0.key] != nil }
        var list: [AppRow] = []
        list.reserveCapacity(rows.count)
        for (pid, var row) in rows {
            row.lastPlayed = lastPlayed[pid]
            row.recent = row.recentlyPlayed
            row.windows = windowsByPID[pid] ?? []
            row.location = locations[pid]
            list.append(row)
        }
        list.sort { a, b in
            let ra = rank(a), rb = rank(b)
            return ra != rb ? ra < rb : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }

        recordHistory(rows: rows, orphans: unowned, now: now)
        mixer.sync(list.filter(\.isPlaying).map { AudioSource(app: $0.id, processObjects: $0.audioObjects) })
        if now.timeIntervalSince(lastLocate) > 1 {
            lastLocate = now
            locateSounding(list.filter { $0.isPlaying || $0.recent })
        }

        publish(list)
        let o = unowned.sorted { $0.executableName < $1.executableName }
        if o != orphans { orphans = o }
        if result.windows != allWindows { allWindows = result.windows }
        lastScan = now
    }

    /// Fills icons for the rows that are shown and assigns only what changed.
    private func publish(_ list: [AppRow]) {
        let withIcons = list.map { row -> AppRow in
            guard row.isRegular || row.isPlaying || row.isRecording || row.recent || showBackgroundApps else { return row }
            return AppRow(id: row.id, name: row.name, bundleID: row.bundleID, icon: icon(for: row.id),
                          isRegular: row.isRegular, isPlaying: row.isPlaying, isRecording: row.isRecording,
                          outputDevices: row.outputDevices, inputDevices: row.inputDevices, helpers: row.helpers,
                          helperPIDs: row.helperPIDs, audioObjects: row.audioObjects, location: row.location,
                          lastPlayed: row.lastPlayed, windows: row.windows, recent: row.recent)
        }
        if withIcons != apps { apps = withIcons }
        let playing = withIcons.filter { $0.isPlaying || $0.recent }
        if playing != playingApps { playingApps = playing }
        let visible = withIcons.filter { showBackgroundApps || $0.isRegular || $0.isPlaying || $0.isRecording || $0.recent }
        if visible != visibleApps { visibleApps = visible }
    }

    private var playingKeys: Set<String> = []

    /// Appends one event when an app (or unowned process) starts output; extends it while it keeps playing.
    private func recordHistory(rows: [pid_t: AppRow], orphans: [AudioClient], now: Date) {
        var current: [String: (name: String, detail: String)] = [:]
        for row in rows.values where row.isPlaying {
            current["app:\(row.id)"] = (row.name, (row.helpers.sorted() + row.outputDevices.sorted()).joined(separator: " · "))
        }
        for c in orphans where c.isRunningOutput {
            current["proc:\(c.pid)"] = (c.executableName, c.outputDevices.joined(separator: ", "))
        }
        for (key, info) in current {
            if playingKeys.contains(key), let i = history.firstIndex(where: { $0.key == key }) {
                if now.timeIntervalSince(history[i].end) >= 1 { history[i].end = now }   // 1 s granularity: fewer redraws
            } else {
                history.insert(SoundEvent(key: key, name: info.name, detail: info.detail, start: now, end: now), at: 0)
            }
        }
        playingKeys = Set(current.keys)
        if history.count > 200 { history.removeLast(history.count - 200) }
    }

    private func rank(_ row: AppRow) -> Int {
        if row.isPlaying { return 0 }
        if row.recent { return 1 }
        if row.isRecording { return 2 }
        return row.isRegular ? 3 : 4
    }

    /// "on the left display (DELL U2720Q)" style description for an app's windows.
    func whereIs(_ row: AppRow) -> String {
        guard let biggest = row.windows.max(by: { $0.frame.area < $1.frame.area }) else {
            return "no visible window"
        }
        let center = CGPoint(x: biggest.frame.midX, y: biggest.frame.midY)
        guard let display = displays.first(where: { $0.frame.contains(center) })
                ?? displays.min(by: { $0.frame.distance(to: center) < $1.frame.distance(to: center) })
        else { return "off-screen" }
        if display.isMain { return "on the main display (\(display.name))" }
        guard let main = displays.first(where: \.isMain) else { return "on \(display.name)" }
        var parts: [String] = []
        if display.frame.maxX <= main.frame.minX { parts.append("left") }
        if display.frame.minX >= main.frame.maxX { parts.append("right") }
        if display.frame.maxY <= main.frame.minY { parts.append("above") }
        if display.frame.minY >= main.frame.maxY { parts.append("below") }
        let side = parts.isEmpty ? "another" : parts.joined(separator: "/")
        return "on the \(side) display (\(display.name))"
    }

    /// Window and tab lookups can be slow (Accessibility, AppleScript), so they run off the scan path.
    private func locateSounding(_ rows: [AppRow]) {
        for row in rows {
            Task { [weak self] in
                guard let self else { return }
                let loc = await self.locator.locate(app: row.id, bundleID: row.bundleID, helperPIDs: row.helperPIDs)
                guard self.locations[row.id] != loc else { return }
                self.locations[row.id] = loc
                self.publish(self.apps.map { r in var r = r; if r.id == row.id { r.location = loc }; return r })
            }
        }
        locations = locations.filter { key, _ in rows.contains { $0.id == key } }
    }

    func jump(to row: AppRow) {
        if let loc = row.location, loc.space != .noWindow {
            locator.jump(app: row.id, bundleID: row.bundleID, to: loc)
        } else {
            bringToFront(row.id)
        }
    }

    func bringToFront(_ pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        // macOS 14+ cooperative activation: we must hand activation over, or the request is ignored.
        NSApplication.shared.yieldActivation(to: app)
        app.activate(options: [.activateAllWindows])
    }
}

struct SoundEvent: Identifiable {
    let id = UUID()
    let key: String
    let name: String
    let detail: String
    let start: Date
    var end: Date
}

extension CGRect {
    var area: CGFloat { width * height }
    func distance(to p: CGPoint) -> CGFloat {
        let dx = max(minX - p.x, 0, p.x - maxX)
        let dy = max(minY - p.y, 0, p.y - maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}

import AppKit
import CoreAudio
import Observation

struct AppRow: Identifiable {
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

    var recentlyPlayed: Bool {
        guard let lastPlayed else { return false }
        return Date().timeIntervalSince(lastPlayed) < RadarModel.holdSeconds
    }
}

@Observable
@MainActor
final class RadarModel {
    nonisolated static let holdSeconds: TimeInterval = 4   // keep short blips (alert sounds) visible

    var apps: [AppRow] = []
    var orphans: [AudioClient] = []            // audio processes with no GUI owner
    var displays: [DisplayBox] = []
    var allWindows: [WindowBox] = []
    var showBackgroundApps = false
    var lastScan = Date()
    var history: [SoundEvent] = []            // newest first, one entry per sound burst

    let mixer: AudioMixing
    let locator: SoundLocating
    private var locations: [pid_t: SourceLocation] = [:]
    private var lastLocate = Date.distantPast

    private var lastPlayed: [pid_t: Date] = [:]
    private var timer: Timer?

    init(mixer: AudioMixing? = nil, locator: SoundLocating? = nil) {
        self.mixer = mixer ?? NullMixer()
        self.locator = locator ?? NullLocator()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    var playingApps: [AppRow] { apps.filter { $0.isPlaying || $0.recentlyPlayed } }

    var visibleApps: [AppRow] {
        apps.filter { showBackgroundApps || $0.isRegular || $0.isPlaying || $0.isRecording || $0.recentlyPlayed }
    }

    func refresh() {
        let running = NSWorkspace.shared.runningApplications
        let byPID = Dictionary(running.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
        var rows: [pid_t: AppRow] = [:]
        for app in running {
            rows[app.processIdentifier] = AppRow(
                id: app.processIdentifier,
                name: app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)",
                bundleID: app.bundleIdentifier, icon: app.icon,
                isRegular: app.activationPolicy == .regular)
        }

        var unowned: [AudioClient] = []
        let now = Date()
        // Our own taps make Sound Radar look like a player; never list ourselves.
        let selfPID = ProcessInfo.processInfo.processIdentifier
        for client in AudioScanner.scan() where (client.isRunningOutput || client.isRunningInput) && client.pid != selfPID {
            guard let owner = ProcessTree.owningApp(for: client.pid, apps: byPID),
                  var row = rows[owner.processIdentifier] else {
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
            if client.pid != owner.processIdentifier {
                row.helpers.insert(client.executableName)
                row.helperPIDs.append(client.pid)
            }
            rows[row.id] = row
        }

        let windows = WindowScanner.windows()
        let windowsByPID = Dictionary(grouping: windows, by: \.pid)
        for (pid, var row) in rows {
            row.lastPlayed = lastPlayed[pid]
            row.windows = windowsByPID[pid] ?? []
            row.location = locations[pid]
            rows[pid] = row
        }
        lastPlayed = lastPlayed.filter { rows[$0.key] != nil }
        recordHistory(rows: rows, orphans: unowned, now: now)
        mixer.sync(rows.values.filter { $0.isPlaying }.map { AudioSource(app: $0.id, processObjects: $0.audioObjects) })
        if now.timeIntervalSince(lastLocate) > 1 {
            lastLocate = now
            locateSounding(Array(rows.values.filter { $0.isPlaying || $0.recentlyPlayed }))
        }

        apps = rows.values.sorted { a, b in
            let ra = rank(a), rb = rank(b)
            return ra != rb ? ra < rb : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        orphans = unowned.sorted { $0.executableName < $1.executableName }
        allWindows = windows
        displays = WindowScanner.displays()
        lastScan = now
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
                history[i].end = now
            } else {
                history.insert(SoundEvent(key: key, name: info.name, detail: info.detail, start: now, end: now), at: 0)
            }
        }
        playingKeys = Set(current.keys)
        if history.count > 200 { history.removeLast(history.count - 200) }
    }

    private func rank(_ row: AppRow) -> Int {
        if row.isPlaying { return 0 }
        if row.recentlyPlayed { return 1 }
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
                self.locations[row.id] = loc
                if let i = self.apps.firstIndex(where: { $0.id == row.id }) { self.apps[i].location = loc }
            }
        }
        locations = locations.filter { key, _ in rows.contains { $0.id == key } || apps.contains { $0.id == key && ($0.isPlaying || $0.recentlyPlayed) } }
    }

    func jump(to row: AppRow) {
        if let loc = row.location, loc.space != .noWindow {
            locator.jump(app: row.id, bundleID: row.bundleID, to: loc)
        } else {
            bringToFront(row.id)
        }
    }

    func bringToFront(_ pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
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

import AppKit
import ApplicationServices
import CoreGraphics

@MainActor
final class SoundLocator: SoundLocating {
    static let browserTabsKey = "locate.browserTabs"

    var accessibilityGranted: Bool { AXIsProcessTrusted() }
    func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
    var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }
    func requestScreenRecording() { _ = CGRequestScreenCaptureAccess() }

    /// Off by default: each browser triggers an Automation prompt.
    var browserTabsEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.browserTabsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.browserTabsKey); cache.removeAll() }
    }

    private struct Cached { let at: Date; let title: String?; let url: String? }
    private var cache: [pid_t: Cached] = [:]
    private var backoffUntil: [pid_t: Date] = [:]
    private var lastLocation: [pid_t: SourceLocation] = [:]
    private var inFlight = InFlightGuard()
    private let runner = ScriptRunner()
    /// Own serial queue so a jump never waits behind lookups.
    private let jumpRunner = ScriptRunner()
    nonisolated private static let axTimeout: Float = 0.25

    // MARK: locate

    func locate(app: pid_t, bundleID: String?, helperPIDs: [pid_t]) async -> SourceLocation {
        guard inFlight.begin(app) else {
            return lastLocation[app] ?? SourceLocation(windowTitle: nil, space: .noWindow, windowNumber: nil)
        }
        defer { inFlight.end(app) }
        let hidden = NSRunningApplication(processIdentifier: app)?.isHidden ?? false
        let pick = await Self.windowPick(pid: app, appHidden: hidden, axGranted: AXIsProcessTrusted())
        var loc = SourceLocation(windowTitle: pick.title, space: pick.space, windowNumber: pick.windowNumber)
        defer { lastLocation[app] = loc }
        guard pick.space != .noWindow, browserTabsEnabled, let fam = BrowserFamily.of(bundleID: bundleID) else { return loc }
        let now = Date()
        if let c = cache[app], now.timeIntervalSince(c.at) < 10 {
            loc.tabTitle = c.title; loc.tabURL = c.url
            return loc
        }
        if LocatePolicy.inBackoff(until: backoffUntil[app], now: now) { return loc }
        // Negative entry first: whatever happens to the script, the next second reuses it.
        cache[app] = Cached(at: now, title: nil, url: nil)
        let reply = await runner.run(BrowserScripts.activeTab(fam, windowHint: pick.title), timeout: 1.5)
        backoffUntil[app] = LocatePolicy.backoffUntil(reply: reply, now: Date())
        let parsed = LocatePure.parseTabReply(reply)
        cache[app] = Cached(at: Date(), title: parsed?.title, url: parsed?.url)
        loc.tabTitle = parsed?.title; loc.tabURL = parsed?.url
        return loc
    }

    /// CGWindowList (+ AX only when the picked window is offscreen) on a background queue.
    private nonisolated static func windowPick(pid: pid_t, appHidden: Bool, axGranted: Bool) async -> WindowPick {
        await withCheckedContinuation { (cont: CheckedContinuation<WindowPick, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
                var pick = LocatePure.pick(windows: list, pid: pid, appHidden: appHidden, axMinimized: false)
                if axGranted, LocatePolicy.needsAXMinimizedCheck(pick) {
                    let ax = axWindows(pid)
                    let allMin = !ax.isEmpty && ax.allSatisfy { isMinimized($0) }
                    pick = LocatePure.pick(windows: list, pid: pid, appHidden: appHidden, axMinimized: allMin)
                }
                cont.resume(returning: pick)
            }
        }
    }

    // MARK: jump

    func jump(app: pid_t, bundleID: String?, to location: SourceLocation) {
        let running = NSRunningApplication(processIdentifier: app)
        if running?.isHidden == true { running?.unhide() }
        if browserTabsEnabled, let fam = BrowserFamily.of(bundleID: bundleID), let url = location.tabURL {
            let script = BrowserScripts.selectTab(fam, url: url)
            Task { [jumpRunner] in _ = await jumpRunner.run(script, timeout: 1.5) }
        }
        if let running {
            // macOS 14+ cooperative activation: hand activation over, or the request is ignored.
            NSApplication.shared.yieldActivation(to: running)
            running.activate(options: [.activateAllWindows])
        }
        guard accessibilityGranted else { return }
        let wins = Self.axWindows(app)
        let title = location.windowTitle ?? location.tabTitle
        let target = wins.first { w in title != nil && Self.title(of: w) == title }
            ?? wins.first { w in
                guard let t = Self.title(of: w), let want = title else { return false }
                return t.hasPrefix(want) || want.hasPrefix(t)
            }
            ?? (wins.count == 1 ? wins[0] : nil)
        guard let w = target else { return }
        if Self.isMinimized(w) { AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
        AXUIElementPerformAction(w, kAXRaiseAction as CFString)
    }

    // MARK: AX helpers

    private nonisolated static func axWindows(_ pid: pid_t) -> [AXUIElement] {
        guard AXIsProcessTrusted() else { return [] }
        var v: CFTypeRef?
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, axTimeout)
        guard AXUIElementCopyAttributeValue(el, kAXWindowsAttribute as CFString, &v) == .success else { return [] }
        let wins = (v as? [AXUIElement]) ?? []
        for w in wins { AXUIElementSetMessagingTimeout(w, axTimeout) }
        return wins
    }

    private nonisolated static func title(of w: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private nonisolated static func isMinimized(_ w: AXUIElement) -> Bool {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &v) == .success else { return false }
        return (v as? Bool) ?? false
    }
}

/// Runs NSAppleScript on one dedicated serial queue (NSAppleScript is not thread-safe).
final class ScriptRunner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "soundradar.locate.applescript")

    private final class Once: @unchecked Sendable {
        private let lock = NSLock(); private var done = false
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }

    func run(_ source: String, timeout: TimeInterval) async -> String? {
        let enqueued = Date()
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let once = Once()
            queue.async {
                // The caller already timed out: do not spend queue time on a dead script.
                if LocatePolicy.shouldSkipStale(enqueuedAt: enqueued, now: Date(), timeout: timeout) {
                    if once.claim() { cont.resume(returning: nil) }
                    return
                }
                var result: String?
                if let script = NSAppleScript(source: source) {
                    var err: NSDictionary?
                    let d = script.executeAndReturnError(&err)
                    if err == nil { result = d.stringValue }
                }
                if once.claim() { cont.resume(returning: result) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if once.claim() { cont.resume(returning: nil) }
            }
        }
    }
}

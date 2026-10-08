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
    private let runner = ScriptRunner()

    // MARK: locate

    func locate(app: pid_t, bundleID: String?, helperPIDs: [pid_t]) async -> SourceLocation {
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        let running = NSRunningApplication(processIdentifier: app)
        let ax = axWindows(app)
        let allMin = !ax.isEmpty && ax.allSatisfy { Self.isMinimized($0) }
        let pick = LocatePure.pick(windows: list, pid: app, appHidden: running?.isHidden ?? false, axMinimized: allMin)
        var loc = SourceLocation(windowTitle: pick.title, space: pick.space, windowNumber: pick.windowNumber)
        guard pick.space != .noWindow, browserTabsEnabled, let fam = BrowserFamily.of(bundleID: bundleID) else { return loc }
        if let c = cache[app], Date().timeIntervalSince(c.at) < 10 {
            loc.tabTitle = c.title; loc.tabURL = c.url
            return loc
        }
        let reply = await runner.run(BrowserScripts.activeTab(fam, windowHint: pick.title), timeout: 1.5)
        let parsed = LocatePure.parseTabReply(reply)
        cache[app] = Cached(at: Date(), title: parsed?.title, url: parsed?.url)
        loc.tabTitle = parsed?.title; loc.tabURL = parsed?.url
        return loc
    }

    // MARK: jump

    func jump(app: pid_t, bundleID: String?, to location: SourceLocation) {
        let running = NSRunningApplication(processIdentifier: app)
        if running?.isHidden == true { running?.unhide() }
        if browserTabsEnabled, let fam = BrowserFamily.of(bundleID: bundleID), let url = location.tabURL {
            let script = BrowserScripts.selectTab(fam, url: url)
            Task { [runner] in _ = await runner.run(script, timeout: 1.5) }
        }
        running?.activate(options: [.activateAllWindows])
        guard accessibilityGranted else { return }
        let wins = axWindows(app)
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

    private func axWindows(_ pid: pid_t) -> [AXUIElement] {
        guard accessibilityGranted else { return [] }
        var v: CFTypeRef?
        let el = AXUIElementCreateApplication(pid)
        guard AXUIElementCopyAttributeValue(el, kAXWindowsAttribute as CFString, &v) == .success else { return [] }
        return (v as? [AXUIElement]) ?? []
    }

    private static func title(of w: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private static func isMinimized(_ w: AXUIElement) -> Bool {
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
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let once = Once()
            queue.async {
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

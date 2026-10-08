import Foundation

/// Pure, permission-free parts of the locator. Testable with hand-built dictionaries.
struct WindowPick: Equatable, Sendable {
    var windowNumber: UInt32?
    var title: String?
    var space: SpaceStatus
}

enum LocatePure {
    /// Chooses the app's best window from CGWindowList-style dictionaries
    /// (kCGWindowOwnerPID, kCGWindowLayer, kCGWindowBounds, kCGWindowName, kCGWindowIsOnscreen, kCGWindowNumber).
    /// Candidates: owner == pid, layer 0, height > 100. Preference: onscreen, then titled, then largest area.
    /// Space: onscreen -> thisDesktop; else hidden app -> hidden; else AX-minimized -> minimized; else otherDesktop.
    static func pick(windows: [[String: Any]], pid: pid_t, appHidden: Bool, axMinimized: Bool) -> WindowPick {
        struct Cand { let number: UInt32; let title: String?; let onscreen: Bool; let area: Double }
        var cands: [Cand] = []
        for w in windows {
            guard (w["kCGWindowOwnerPID"] as? Int).map({ pid_t($0) }) == pid,
                  (w["kCGWindowLayer"] as? Int) == 0,
                  let number = (w["kCGWindowNumber"] as? Int).map({ UInt32($0) }) else { continue }
            var width = 0.0, height = 0.0
            if let b = w["kCGWindowBounds"] as? [String: Any] {
                width = (b["Width"] as? NSNumber)?.doubleValue ?? 0
                height = (b["Height"] as? NSNumber)?.doubleValue ?? 0
            }
            guard height > 100 else { continue }
            let name = (w["kCGWindowName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            cands.append(Cand(number: number, title: name,
                              onscreen: (w["kCGWindowIsOnscreen"] as? Bool) ?? false, area: width * height))
        }
        guard let best = cands.min(by: { a, b in
            if a.onscreen != b.onscreen { return a.onscreen }
            if (a.title != nil) != (b.title != nil) { return a.title != nil }
            return a.area > b.area
        }) else { return WindowPick(windowNumber: nil, title: nil, space: .noWindow) }
        let space: SpaceStatus = best.onscreen ? .thisDesktop
            : appHidden ? .hidden
            : axMinimized ? .minimized : .otherDesktop
        return WindowPick(windowNumber: best.number, title: best.title, space: space)
    }

    /// Escapes text for use inside an AppleScript double-quoted string literal.
    static func escapeAppleScript(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n", "\r": out += " "
            default: out.append(ch)
            }
        }
        return out
    }

    /// Splits "title<US>url" as returned by the active-tab scripts.
    static func parseTabReply(_ s: String?) -> (title: String?, url: String?)? {
        guard let s, let i = s.firstIndex(of: "\u{1F}") else { return nil }
        let t = String(s[..<i]), u = String(s[s.index(after: i)...])
        return (t.isEmpty ? nil : t, u.isEmpty ? nil : u)
    }
}

/// Pure scheduling decisions for the locator (no clocks, no AppleScript).
enum LocatePolicy {
    /// How long a pid is left alone after one of its scripts timed out.
    static let backoff: TimeInterval = 30

    /// A queued script whose caller has already given up must not run.
    static func shouldSkipStale(enqueuedAt: Date, now: Date, timeout: TimeInterval) -> Bool {
        now.timeIntervalSince(enqueuedAt) >= timeout
    }

    /// True while a pid is in its post-timeout back-off window.
    static func inBackoff(until: Date?, now: Date) -> Bool {
        guard let until else { return false }
        return now < until
    }

    /// Back-off end after a script outcome: a nil reply (timeout or failure) starts one.
    static func backoffUntil(reply: String?, now: Date) -> Date? {
        reply == nil ? now.addingTimeInterval(backoff) : nil
    }

    /// AX windows are only needed to tell "minimized" from "other desktop", i.e. for an
    /// offscreen window of an app that is not hidden.
    static func needsAXMinimizedCheck(_ pick: WindowPick) -> Bool {
        pick.space == .otherDesktop
    }
}

/// At most one locate per pid at a time.
struct InFlightGuard {
    private var pids: Set<pid_t> = []
    /// Returns false when `pid` already has a locate in flight.
    mutating func begin(_ pid: pid_t) -> Bool { pids.insert(pid).inserted }
    mutating func end(_ pid: pid_t) { pids.remove(pid) }
    func isInFlight(_ pid: pid_t) -> Bool { pids.contains(pid) }
}

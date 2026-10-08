import AppKit
import Darwin

/// Maps a helper process (WebContent, simulator daemons, XPC services) to the app the user sees.
enum ProcessTree {
    static func path(of pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let len = proc_pidpath(pid, &buf, UInt32(buf.count))
        return len > 0 ? String(cString: buf) : nil
    }

    static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 1 ? ppid : nil
    }

    /// Private but stable libsystem call used by Activity Monitor ("responsible process").
    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private static let responsibleFn: ResponsibleFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
        else { return nil }
        return unsafeBitCast(sym, to: ResponsibleFn.self)
    }()

    /// Returns the app that owns `pid`, preferring a Dock (regular) app over hidden agents
    /// such as SimulatorTrampoline, which would otherwise swallow the attribution.
    static func owningApp(for pid: pid_t, apps: [pid_t: NSRunningApplication]) -> NSRunningApplication? {
        var candidates: [pid_t] = [pid]
        if let fn = responsibleFn {
            let r = fn(pid)
            if r > 0 { candidates.append(r) }
        }
        var current = pid
        for _ in 0..<16 {
            guard let p = parent(of: current) else { break }
            candidates.append(p)
            current = p
        }
        let found = candidates.compactMap { apps[$0] }
        if let regular = found.first(where: { $0.activationPolicy == .regular }) { return regular }
        // Simulated devices run under launchd_sim, not under Simulator.app.
        if let path = path(of: pid), path.contains("/CoreSimulator/"),
           let sim = apps.values.first(where: { $0.bundleIdentifier == "com.apple.iphonesimulator" }) {
            return sim
        }
        return found.first
    }
}

import Foundation

enum BrowserFamily {
    case chrome(appID: String), arc, safari

    static func of(bundleID: String?) -> BrowserFamily? {
        switch bundleID {
        case "company.thebrowser.Browser": return .arc
        case "com.apple.Safari": return .safari
        case "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac": return .chrome(appID: bundleID!)
        default: return nil
        }
    }

    var appID: String {
        switch self {
        case .chrome(let id): return id
        case .arc: return "company.thebrowser.Browser"
        case .safari: return "com.apple.Safari"
        }
    }
}

/// AppleScript sources. Every interpolated value goes through LocatePure.escapeAppleScript.
enum BrowserScripts {
    private static func wrap(_ app: String, _ body: String) -> String {
        "with timeout of 2 seconds\ntell application id \"\(LocatePure.escapeAppleScript(app))\"\n\(body)\nend tell\nend timeout"
    }

    /// Returns "title<US>url" of the active tab of the window whose name starts with `hint`, else the front window.
    static func activeTab(_ f: BrowserFamily, windowHint: String?) -> String {
        let hint = LocatePure.escapeAppleScript(windowHint ?? "")
        let tab: String
        switch f {
        case .chrome, .arc: tab = "active tab of w"
        case .safari: tab = "current tab of w"
        }
        let titleProp = { if case .safari = f { return "name" } else { return "title" } }()
        let body = """
        if (count of windows) is 0 then return ""
        set w to front window
        if "\(hint)" is not "" then
            repeat with cand in windows
                try
                    if (name of cand) starts with "\(hint)" then
                        set w to cand
                        exit repeat
                    end if
                end try
            end repeat
        end if
        set t to \(tab)
        return (\(titleProp) of t) & (ASCII character 31) & (URL of t)
        """
        return wrap(f.appID, body)
    }

    /// Selects the tab whose URL equals `url` and brings its window to index 1. Returns "ok" or "miss".
    static func selectTab(_ f: BrowserFamily, url: String) -> String {
        let u = LocatePure.escapeAppleScript(url)
        let pick: String
        switch f {
        case .chrome: pick = "set active tab index of w to ti"
        case .arc: pick = "tell tab ti of w to select"
        case .safari: pick = "set current tab of w to tab ti of w"
        }
        let body = """
        repeat with wi from 1 to count of windows
            set w to window wi
            repeat with ti from 1 to count of tabs of w
                if (URL of tab ti of w) is "\(u)" then
                    \(pick)
                    set index of w to 1
                    return "ok"
                end if
            end repeat
        end repeat
        return "miss"
        """
        return wrap(f.appID, body)
    }
}

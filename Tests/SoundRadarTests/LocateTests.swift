import Foundation
import XCTest
@testable import SoundRadar

final class LocateTests: XCTestCase {
    /// Shaped like CGWindowListCopyWindowInfo: numbers are NSNumber, bounds is a dictionary of NSNumber,
    /// kCGWindowIsOnscreen is present (true) only for windows on the current Space, kCGWindowName may be absent.
    private func win(pid: Int = 42, layer: Int = 0, number: Int, w: Double = 800, h: Double = 600,
                     name: String? = nil, onscreen: Bool = false) -> [String: Any] {
        var d: [String: Any] = [
            "kCGWindowOwnerPID": NSNumber(value: pid),
            "kCGWindowLayer": NSNumber(value: layer),
            "kCGWindowNumber": NSNumber(value: number),
            "kCGWindowBounds": ["Width": NSNumber(value: w), "Height": NSNumber(value: h),
                                "X": NSNumber(value: 0), "Y": NSNumber(value: 0)] as [String: Any],
        ]
        if let name { d["kCGWindowName"] = name }
        if onscreen { d["kCGWindowIsOnscreen"] = NSNumber(value: true) }
        return d
    }

    private func pick(_ ws: [[String: Any]], hidden: Bool = false, min: Bool = false) -> WindowPick {
        LocatePure.pick(windows: ws, pid: 42, appHidden: hidden, axMinimized: min)
    }

    // MARK: pick

    func testOnscreenBeatsBiggerOffscreen() {
        let r = pick([win(number: 1, w: 3000, h: 2000, name: "Big", onscreen: false),
                      win(number: 2, w: 400, h: 300, onscreen: true)])
        XCTAssertEqual(r.windowNumber, 2)
        XCTAssertEqual(r.space, .thisDesktop)
    }

    func testTitledBeatsUntitledWhenNeitherOnscreen() {
        let r = pick([win(number: 1, w: 3000, h: 2000), win(number: 2, w: 400, h: 300, name: "Doc")])
        XCTAssertEqual(r.windowNumber, 2)
        XCTAssertEqual(r.title, "Doc")
    }

    func testLargestAreaBreaksTies() {
        let r = pick([win(number: 1, w: 400, h: 300, name: "a"), win(number: 2, w: 900, h: 700, name: "b")])
        XCTAssertEqual(r.windowNumber, 2)
    }

    func testOtherPidNonZeroLayerAndShortWindowsIgnored() {
        let r = pick([win(pid: 7, number: 1, onscreen: true),
                      win(layer: 25, number: 2, onscreen: true),
                      win(number: 3, h: 100, onscreen: true),
                      win(number: 4, h: 40, onscreen: true)])
        XCTAssertNil(r.windowNumber)
        XCTAssertEqual(r.space, .noWindow)
    }

    func testHeightJustOver100IsKept() {
        XCTAssertEqual(pick([win(number: 9, h: 101)]).windowNumber, 9)
    }

    func testOffscreenAppHiddenIsHidden() {
        XCTAssertEqual(pick([win(number: 1)], hidden: true, min: true).space, .hidden)
    }

    func testOffscreenAXMinimizedIsMinimized() {
        XCTAssertEqual(pick([win(number: 1)], min: true).space, .minimized)
    }

    func testOffscreenOtherwiseIsOtherDesktop() {
        XCTAssertEqual(pick([win(number: 1)]).space, .otherDesktop)
    }

    func testOnscreenIgnoresHiddenAndMinimizedFlags() {
        XCTAssertEqual(pick([win(number: 1, onscreen: true)], hidden: true, min: true).space, .thisDesktop)
    }

    func testNoCandidatesIsNoWindowWithNilNumber() {
        let r = pick([])
        XCTAssertNil(r.windowNumber)
        XCTAssertNil(r.title)
        XCTAssertEqual(r.space, .noWindow)
    }

    func testEmptyNameIsNilTitle() {
        let r = pick([win(number: 1, name: "")])
        XCTAssertEqual(r.windowNumber, 1)
        XCTAssertNil(r.title)
    }

    func testEmptyNameDoesNotCountAsTitled() {
        let r = pick([win(number: 1, w: 3000, h: 2000, name: ""), win(number: 2, w: 400, h: 300, name: "T")])
        XCTAssertEqual(r.windowNumber, 2)
    }

    func testRealisticTypesBridge() {
        // Swift Int / Bool literals (as bridged from NSNumber / NSCFBoolean) behave the same.
        let w: [String: Any] = ["kCGWindowOwnerPID": 42, "kCGWindowLayer": 0, "kCGWindowNumber": 77,
                                "kCGWindowBounds": ["Width": 500, "Height": 400],
                                "kCGWindowName": "T", "kCGWindowIsOnscreen": true]
        let r = pick([w])
        XCTAssertEqual(r.windowNumber, 77)
        XCTAssertEqual(r.space, .thisDesktop)
    }

    // MARK: escapeAppleScript

    func testEscapeQuotesBackslashesNewlines() {
        XCTAssertEqual(LocatePure.escapeAppleScript(#"a"b"#), #"a\"b"#)
        XCTAssertEqual(LocatePure.escapeAppleScript(#"a\b"#), #"a\\b"#)
        XCTAssertEqual(LocatePure.escapeAppleScript("a\nb\rc"), "a b c")
        XCTAssertEqual(LocatePure.escapeAppleScript(""), "")
    }

    /// Walks an AppleScript string literal body: a bare `"` ends it, `\` escapes the next character.
    private func literalTerminatesEarly(_ escaped: String) -> Bool {
        var it = escaped.makeIterator()
        while let c = it.next() {
            if c == "\\" { _ = it.next() } else if c == "\"" { return true }
        }
        return false
    }

    func testEscapedURLCannotTerminateLiteral() {
        let url = #"https://x.com/a"b\c"#
        XCTAssertTrue(literalTerminatesEarly(url), "sanity: the raw value would break out")
        let esc = LocatePure.escapeAppleScript(url)
        XCTAssertFalse(literalTerminatesEarly(esc))
        XCTAssertEqual(esc, #"https://x.com/a\"b\\c"#)
        let nasty = LocatePure.escapeAppleScript("\\\" & (do shell script \"x\") & \"\\")
        XCTAssertFalse(literalTerminatesEarly(nasty))
    }

    // MARK: parseTabReply

    func testParseTabReply() {
        let r = LocatePure.parseTabReply("My Title\u{1F}https://a.com/x")
        XCTAssertEqual(r?.title, "My Title")
        XCTAssertEqual(r?.url, "https://a.com/x")
        let e = LocatePure.parseTabReply("\u{1F}")
        XCTAssertNotNil(e)
        XCTAssertNil(e?.title)
        XCTAssertNil(e?.url)
        let t = LocatePure.parseTabReply("T\u{1F}")
        XCTAssertEqual(t?.title, "T")
        XCTAssertNil(t?.url)
        let u = LocatePure.parseTabReply("\u{1F}https://a.com")
        XCTAssertNil(u?.title)
        XCTAssertEqual(u?.url, "https://a.com")
    }

    func testParseTabReplyNoSeparatorOrNilIsNil() {
        XCTAssertNil(LocatePure.parseTabReply("no separator"))
        XCTAssertNil(LocatePure.parseTabReply(""))
        XCTAssertNil(LocatePure.parseTabReply(nil))
    }

    func testParseTabReplyKeepsLaterSeparatorsInURL() {
        let r = LocatePure.parseTabReply("T\u{1F}u\u{1F}v")
        XCTAssertEqual(r?.url, "u\u{1F}v")
    }

    // MARK: BrowserFamily

    func testBrowserFamilyOf() {
        guard case .arc? = BrowserFamily.of(bundleID: "company.thebrowser.Browser") else { return XCTFail("arc") }
        guard case .safari? = BrowserFamily.of(bundleID: "com.apple.Safari") else { return XCTFail("safari") }
        for id in ["com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac"] {
            guard case .chrome(let a)? = BrowserFamily.of(bundleID: id) else { return XCTFail(id) }
            XCTAssertEqual(a, id)
            XCTAssertEqual(BrowserFamily.of(bundleID: id)?.appID, id)
        }
        XCTAssertEqual(BrowserFamily.arc.appID, "company.thebrowser.Browser")
        XCTAssertEqual(BrowserFamily.safari.appID, "com.apple.Safari")
        XCTAssertNil(BrowserFamily.of(bundleID: "org.mozilla.firefox"))
        XCTAssertNil(BrowserFamily.of(bundleID: nil))
    }

    // MARK: BrowserScripts

    func testSelectTabEmbedsEscapedURLAndApp() {
        let url = #"https://x.com/a"b\c"#
        let esc = LocatePure.escapeAppleScript(url)
        for (f, id) in [(BrowserFamily.chrome(appID: "com.google.Chrome"), "com.google.Chrome"),
                        (.arc, "company.thebrowser.Browser"), (.safari, "com.apple.Safari")] {
            let s = BrowserScripts.selectTab(f, url: url)
            XCTAssertTrue(s.contains("tell application id \"\(id)\""), id)
            XCTAssertTrue(s.contains("is \"\(esc)\""), id)
            XCTAssertFalse(s.contains(url), "raw URL must not appear: \(id)")
        }
    }

    func testSelectTabPerFamilyPick() {
        XCTAssertTrue(BrowserScripts.selectTab(.chrome(appID: "com.brave.Browser"), url: "u").contains("set active tab index of w to ti"))
        XCTAssertTrue(BrowserScripts.selectTab(.arc, url: "u").contains("tell tab ti of w to select"))
        XCTAssertTrue(BrowserScripts.selectTab(.safari, url: "u").contains("set current tab of w to tab ti of w"))
    }

    func testActiveTabEmbedsEscapedHintAndApp() {
        let hint = #"My "Win" \ x"#
        let esc = LocatePure.escapeAppleScript(hint)
        let s = BrowserScripts.activeTab(.chrome(appID: "com.microsoft.edgemac"), windowHint: hint)
        XCTAssertTrue(s.contains("tell application id \"com.microsoft.edgemac\""))
        XCTAssertTrue(s.contains("starts with \"\(esc)\""))
        XCTAssertTrue(s.contains("active tab of w"))
        XCTAssertFalse(s.contains(hint))
        let safari = BrowserScripts.activeTab(.safari, windowHint: nil)
        XCTAssertTrue(safari.contains("tell application id \"com.apple.Safari\""))
        XCTAssertTrue(safari.contains("current tab of w"))
        XCTAssertTrue(safari.contains("(name of t)"))
        XCTAssertTrue(BrowserScripts.activeTab(.arc, windowHint: nil).contains("(title of t)"))
    }

    // MARK: scheduling policy

    func testStaleScriptSkipDecision() {
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertFalse(LocatePolicy.shouldSkipStale(enqueuedAt: t0, now: t0.addingTimeInterval(1.49), timeout: 1.5))
        XCTAssertTrue(LocatePolicy.shouldSkipStale(enqueuedAt: t0, now: t0.addingTimeInterval(1.5), timeout: 1.5))
        XCTAssertTrue(LocatePolicy.shouldSkipStale(enqueuedAt: t0, now: t0.addingTimeInterval(30), timeout: 1.5))
    }

    func testBackoffDecision() {
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertNil(LocatePolicy.backoffUntil(reply: "ok", now: t0))
        XCTAssertEqual(LocatePolicy.backoffUntil(reply: nil, now: t0), t0.addingTimeInterval(30))
        XCTAssertFalse(LocatePolicy.inBackoff(until: nil, now: t0))
        XCTAssertTrue(LocatePolicy.inBackoff(until: t0.addingTimeInterval(30), now: t0.addingTimeInterval(29.9)))
        XCTAssertFalse(LocatePolicy.inBackoff(until: t0.addingTimeInterval(30), now: t0.addingTimeInterval(30)))
    }

    func testInFlightGuardIsPerPid() {
        var g = InFlightGuard()
        XCTAssertTrue(g.begin(1))
        XCTAssertFalse(g.begin(1))
        XCTAssertTrue(g.begin(2))
        XCTAssertTrue(g.isInFlight(1))
        g.end(1)
        XCTAssertFalse(g.isInFlight(1))
        XCTAssertTrue(g.begin(1))
    }

    func testAXOnlyChecksForOffscreenNotHiddenWindows() {
        XCTAssertFalse(LocatePolicy.needsAXMinimizedCheck(WindowPick(windowNumber: 1, title: nil, space: .thisDesktop)))
        XCTAssertFalse(LocatePolicy.needsAXMinimizedCheck(WindowPick(windowNumber: 1, title: nil, space: .hidden)))
        XCTAssertFalse(LocatePolicy.needsAXMinimizedCheck(WindowPick(windowNumber: nil, title: nil, space: .noWindow)))
        XCTAssertTrue(LocatePolicy.needsAXMinimizedCheck(WindowPick(windowNumber: 1, title: nil, space: .otherDesktop)))
    }
}

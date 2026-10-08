import AppKit
import CoreGraphics

struct WindowBox: Identifiable, Hashable {
    let id: CGWindowID
    let pid: pid_t
    let frame: CGRect   // global coordinates, origin top-left of the main display
}

struct DisplayBox: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
    let frame: CGRect   // same coordinate space as WindowBox
    let isMain: Bool
}

enum WindowScanner {
    /// On-screen, normal-level windows. Bounds and owner PID need no Screen Recording permission.
    static func windows() -> [WindowBox] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let num = info[kCGWindowNumber as String] as? CGWindowID,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict),
                  rect.width > 40, rect.height > 40 else { return nil }
            return WindowBox(id: num, pid: pid, frame: rect)
        }
    }

    static func displays() -> [DisplayBox] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { return nil }
            return DisplayBox(id: id, name: screen.localizedName, frame: CGDisplayBounds(id),
                              isMain: CGDisplayIsMain(id) != 0)
        }
    }
}

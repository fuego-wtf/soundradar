import CoreAudio
import Foundation

/// One Core Audio client process (macOS 14.2+ exposes these as audio objects).
struct AudioClient: Hashable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let executablePath: String
    let isRunningOutput: Bool
    let isRunningInput: Bool
    let outputDevices: [String]
    let inputDevices: [String]

    var executableName: String { (executablePath as NSString).lastPathComponent }
}

/// Reads Core Audio's process objects. Not thread-safe: owned by the scan queue.
/// Static facts (pid, bundle id, path, device names) are read once per object and cached,
/// so a scan of ~150 processes costs two property reads each.
final class AudioScanCache {
    private struct Static { let pid: pid_t; let bundleID: String?; let path: String }
    private var statics: [AudioObjectID: Static] = [:]
    private var deviceNames: [AudioObjectID: String] = [:]

    /// Processes whose input or output is running right now.
    func scan() -> [AudioClient] {
        let objects: [AudioObjectID] = AudioScanner.readArray(AudioScanner.system, kAudioHardwarePropertyProcessObjectList)
        if statics.count > objects.count * 2 {
            let live = Set(objects)
            statics = statics.filter { live.contains($0.key) }
        }
        var clients: [AudioClient] = []
        for obj in objects {
            let out: UInt32 = AudioScanner.readScalar(obj, kAudioProcessPropertyIsRunningOutput) ?? 0
            let inp: UInt32 = AudioScanner.readScalar(obj, kAudioProcessPropertyIsRunningInput) ?? 0
            guard out != 0 || inp != 0 else { continue }
            let st: Static
            if let cached = statics[obj] {
                st = cached
            } else {
                guard let pid: pid_t = AudioScanner.readScalar(obj, kAudioProcessPropertyPID) else { continue }
                st = Static(pid: pid, bundleID: AudioScanner.readString(obj, kAudioProcessPropertyBundleID),
                            path: ProcessTree.path(of: pid) ?? "pid \(pid)")
                statics[obj] = st
            }
            clients.append(AudioClient(
                objectID: obj, pid: st.pid, bundleID: st.bundleID, executablePath: st.path,
                isRunningOutput: out != 0, isRunningInput: inp != 0,
                outputDevices: out != 0 ? names(obj, kAudioObjectPropertyScopeOutput) : [],
                inputDevices: inp != 0 ? names(obj, kAudioObjectPropertyScopeInput) : []))
        }
        return clients
    }

    private func names(_ obj: AudioObjectID, _ scope: AudioObjectPropertyScope) -> [String] {
        let devs: [AudioObjectID] = AudioScanner.readArray(obj, kAudioProcessPropertyDevices, scope: scope)
        return devs.compactMap { d in
            if let n = deviceNames[d] { return n }
            let n = AudioScanner.readString(d, kAudioObjectPropertyName)
            if let n { deviceNames[d] = n }
            return n
        }
    }
}

enum AudioScanner {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    // MARK: - Property helpers

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func readScalar<T>(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                      scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var addr = address(selector, scope)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, value) == noErr else { return nil }
        return value.pointee
    }

    static func readArray<T>(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [T] {
        var addr = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(obj, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, buffer) == noErr else { return [] }
        return Array(UnsafeBufferPointer(start: buffer, count: Int(size) / MemoryLayout<T>.stride))
    }

    static func readString(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector, kAudioObjectPropertyScopeGlobal)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr,
              let str = value?.takeRetainedValue() as String?, !str.isEmpty else { return nil }
        return str
    }
}

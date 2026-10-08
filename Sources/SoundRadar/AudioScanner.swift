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

enum AudioScanner {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    /// Every process Core Audio currently knows about, with its I/O state.
    static func scan() -> [AudioClient] {
        let objects: [AudioObjectID] = readArray(system, kAudioHardwarePropertyProcessObjectList)
        return objects.compactMap { obj in
            guard let pid: pid_t = readScalar(obj, kAudioProcessPropertyPID) else { return nil }
            let out: UInt32 = readScalar(obj, kAudioProcessPropertyIsRunningOutput) ?? 0
            let inp: UInt32 = readScalar(obj, kAudioProcessPropertyIsRunningInput) ?? 0
            let outDevs: [AudioObjectID] = readArray(obj, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput)
            let inDevs: [AudioObjectID] = readArray(obj, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput)
            return AudioClient(
                objectID: obj,
                pid: pid,
                bundleID: readString(obj, kAudioProcessPropertyBundleID),
                executablePath: ProcessTree.path(of: pid) ?? "pid \(pid)",
                isRunningOutput: out != 0,
                isRunningInput: inp != 0,
                outputDevices: outDevs.compactMap { readString($0, kAudioObjectPropertyName) },
                inputDevices: inDevs.compactMap { readString($0, kAudioObjectPropertyName) }
            )
        }
    }

    // MARK: - Property helpers

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func readScalar<T>(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                      scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var addr = address(selector, scope)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, value) == noErr else { return nil }
        return value.pointee
    }

    private static func readArray<T>(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector,
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

    private static func readString(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector, kAudioObjectPropertyScopeGlobal)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr,
              let str = value?.takeRetainedValue() as String?, !str.isEmpty else { return nil }
        return str
    }
}

import CoreAudio
import Foundation
import Synchronization
import os

let mixerLog = Logger(subsystem: "dev.local.soundradar", category: "mixer")

/// State shared with the realtime IOProc. Only atomics and an RT-owned gain; no locks,
/// no allocation, no Swift concurrency on the audio thread.
final class RTState: @unchecked Sendable {
    private let levelBits = Atomic<UInt32>(MixerMath.silenceDB.bitPattern)
    private let targetBits: Atomic<UInt32>
    private let callbacks = Atomic<Int>(0)
    private let failedBuffers = Atomic<Int>(0)
    let processing: Bool
    /// Touched by the audio thread only.
    private var gain: Float

    init(processing: Bool, target: Float) {
        self.processing = processing
        self.targetBits = Atomic<UInt32>(target.bitPattern)
        self.gain = target
    }

    var level: Float { Float(bitPattern: levelBits.load(ordering: .relaxed)) }
    var callbackCount: Int { callbacks.load(ordering: .relaxed) }
    var badBufferCount: Int { failedBuffers.load(ordering: .relaxed) }
    func setTarget(_ g: Float) { targetBits.store(g.bitPattern, ordering: .relaxed) }

    /// Realtime entry point.
    func process(_ inData: UnsafePointer<AudioBufferList>?, _ outData: UnsafeMutablePointer<AudioBufferList>?) {
        callbacks.add(1, ordering: .relaxed)
        var sumSq: Float = 0
        var count = 0
        let target = Float(bitPattern: targetBits.load(ordering: .relaxed))

        let ins = inData.map { UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: $0)) }
        let outs = outData.map { UnsafeMutableAudioBufferListPointer($0) }
        let inCount = ins?.count ?? 0

        if processing, let outs {
            for b in 0..<outs.count {
                let ob = outs[b]
                guard let optr = ob.mData?.assumingMemoryBound(to: Float.self), ob.mNumberChannels > 0 else { continue }
                let outCh = Int(ob.mNumberChannels)
                let outFrames = Int(ob.mDataByteSize) / (MemoryLayout<Float>.size * outCh)
                guard inCount > 0, let ins else {
                    memset(optr, 0, Int(ob.mDataByteSize)); continue
                }
                let ib = ins[min(b, inCount - 1)]
                guard let iptr = ib.mData?.assumingMemoryBound(to: Float.self), ib.mNumberChannels > 0 else {
                    memset(optr, 0, Int(ob.mDataByteSize)); failedBuffers.add(1, ordering: .relaxed); continue
                }
                let inCh = Int(ib.mNumberChannels)
                let inFrames = Int(ib.mDataByteSize) / (MemoryLayout<Float>.size * inCh)
                let frames = min(inFrames, outFrames)
                if frames < outFrames {
                    memset(optr, 0, Int(ob.mDataByteSize))
                }
                sumSq += MixerMath.render(input: iptr, inChannels: inCh, output: optr, outChannels: outCh,
                                          frames: frames, gain: &gain, target: target)
                count += frames * inCh
            }
            if outs.count == 0, let ins {
                for ib in ins {
                    guard let p = ib.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    let n = Int(ib.mDataByteSize) / MemoryLayout<Float>.size
                    sumSq += MixerMath.sumOfSquares(p, count: n); count += n
                }
            }
        } else {
            if let outs {
                for b in 0..<outs.count {
                    let ob = outs[b]
                    if let p = ob.mData { memset(p, 0, Int(ob.mDataByteSize)) }
                }
            }
            if let ins {
                for ib in ins {
                    guard let p = ib.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    let n = Int(ib.mDataByteSize) / MemoryLayout<Float>.size
                    sumSq += MixerMath.sumOfSquares(p, count: n); count += n
                }
            }
        }
        let db = MixerMath.dBFS(sumSquares: sumSq, count: count)
        levelBits.store(db.bitPattern, ordering: .relaxed)
    }
}

enum TapKind {
    case processes([AudioObjectID])
    /// Used only to trigger and test the System Audio Recording permission.
    case permissionProbe
}

struct MixerError: Error, CustomStringConvertible {
    let step: String
    let status: OSStatus
    var description: String { "\(step) failed: \(status) (\(fourCC(status)))" }
}

func fourCC(_ s: OSStatus) -> String {
    let bytes = [UInt8((s >> 24) & 255), UInt8((s >> 16) & 255), UInt8((s >> 8) & 255), UInt8(s & 255)]
    return bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) ? String(decoding: bytes, as: UTF8.self) : "\(s)"
}

/// One app's tap + private aggregate device + IOProc. Not isolated to any actor;
/// the mixer drives it from the main actor.
final class TapChannel: @unchecked Sendable {
    let kind: TapKind
    let objects: Set<AudioObjectID>
    let state: RTState
    let processing: Bool
    private(set) var startedAt: TimeInterval = 0

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var running = false

    init(kind: TapKind, processing: Bool, gain: Float) {
        self.kind = kind
        self.processing = processing
        self.state = RTState(processing: processing, target: gain)
        if case .processes(let o) = kind { objects = Set(o) } else { objects = [] }
    }

    func start(outputUID: String) throws {
        let desc: CATapDescription
        switch kind {
        case .processes(let objs):
            desc = CATapDescription(stereoMixdownOfProcesses: objs)
        case .permissionProbe:
            desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        }
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.muteBehavior = processing ? .muted : .unmuted

        var st = AudioHardwareCreateProcessTap(desc, &tapID)
        guard st == noErr else { tapID = AudioObjectID(kAudioObjectUnknown); throw MixerError(step: "CreateProcessTap", status: st) }

        let tapUID = Self.tapUID(tapID) ?? desc.uuid.uuidString
        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SoundRadarTap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]],
        ]
        st = AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggregateID)
        guard st == noErr else {
            aggregateID = AudioObjectID(kAudioObjectUnknown)
            stop()
            throw MixerError(step: "CreateAggregateDevice", status: st)
        }

        let rt = state
        st = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, inData, _, outData, _ in
            rt.process(inData, outData)
        }
        guard st == noErr, procID != nil else {
            procID = nil
            stop()
            throw MixerError(step: "CreateIOProc", status: st)
        }
        st = AudioDeviceStart(aggregateID, procID)
        guard st == noErr else { stop(); throw MixerError(step: "DeviceStart", status: st) }
        running = true
        startedAt = ProcessInfo.processInfo.systemUptime
    }

    /// Reverse-order teardown; safe to call repeatedly or after a partial start.
    func stop() {
        if aggregateID != kAudioObjectUnknown, let procID {
            if running {
                let s = AudioDeviceStop(aggregateID, procID)
                if s != noErr { mixerLog.error("DeviceStop: \(s)") }
            }
            let s = AudioDeviceDestroyIOProcID(aggregateID, procID)
            if s != noErr { mixerLog.error("DestroyIOProcID: \(s)") }
        }
        procID = nil
        running = false
        if aggregateID != kAudioObjectUnknown {
            let s = AudioHardwareDestroyAggregateDevice(aggregateID)
            if s != noErr { mixerLog.error("DestroyAggregateDevice: \(s)") }
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            let s = AudioHardwareDestroyProcessTap(tapID)
            if s != noErr { mixerLog.error("DestroyProcessTap: \(s)") }
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private static func tapUID(_ tap: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyUID, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let st = AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &uid)
        guard st == noErr, let uid else { mixerLog.error("tap UID read: \(st)"); return nil }
        return uid.takeRetainedValue() as String
    }
}

enum DefaultOutput {
    static var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    static func uid() -> String? {
        var a = address
        var dev = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &dev)
        guard st == noErr, dev != kAudioObjectUnknown else { mixerLog.error("default output: \(st)"); return nil }
        var ua = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal,
                                            mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        st = AudioObjectGetPropertyData(dev, &ua, 0, nil, &size, &cf)
        guard st == noErr, let cf else { mixerLog.error("device UID: \(st)"); return nil }
        return cf.takeRetainedValue() as String
    }
}

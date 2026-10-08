import CoreAudio
import Foundation
import Observation

/// How the default output device is connected.
enum OutputTransport: Sendable {
    case builtIn, bluetooth, usb, hdmi, airPlay, virtual, other

    init(raw: UInt32) {
        switch raw {
        case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: self = .bluetooth
        case kAudioDeviceTransportTypeUSB: self = .usb
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: self = .hdmi
        case kAudioDeviceTransportTypeAirPlay: self = .airPlay
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: self = .virtual
        default: self = .other
        }
    }

    var symbol: String {
        switch self {
        case .builtIn: "hifispeaker.fill"
        case .bluetooth: "headphones"
        case .usb: "cable.connector"
        case .hdmi: "display"
        case .airPlay: "airplayaudio"
        case .virtual: "waveform"
        case .other: "speaker.wave.2.fill"
        }
    }

    var label: String {
        switch self {
        case .builtIn: "Built-in"
        case .bluetooth: "Bluetooth"
        case .usb: "USB"
        case .hdmi: "Display"
        case .airPlay: "AirPlay"
        case .virtual: "Virtual"
        case .other: "Other"
        }
    }
}

/// The default output device: name, transport and master volume, kept live by Core Audio listeners.
@Observable
@MainActor
final class OutputDevice {
    static let shared = OutputDevice()

    private(set) var name: String?
    private(set) var transport: OutputTransport = .other
    /// 0...1, nil when the device has no volume control.
    private(set) var volume: Float?
    private(set) var canSetVolume = false

    @ObservationIgnored private var device = AudioObjectID(kAudioObjectUnknown)
    @ObservationIgnored private var volumeElements: [AudioObjectPropertyElement] = []
    @ObservationIgnored private var deviceListener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var volumeListener: AudioObjectPropertyListenerBlock?

    private init() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.deviceChanged() }
        }
        deviceListener = block
        var addr = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)
        deviceChanged()
    }

    // MARK: Public

    func setVolume(_ value: Float) {
        guard canSetVolume else { return }
        var v = min(max(value, 0), 1)
        for element in volumeElements {
            var addr = Self.address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: element)
            AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        }
        volume = v
    }

    // MARK: Updates

    private func deviceChanged() {
        removeVolumeListener()
        device = Self.defaultDevice()
        name = device == kAudioObjectUnknown ? nil : Self.readName(device)
        transport = device == kAudioObjectUnknown ? .other : Self.readTransport(device)

        volumeElements = []
        canSetVolume = false
        if device != kAudioObjectUnknown {
            // Master control first; many devices expose only per-channel controls (1 and 2).
            for candidate in [[kAudioObjectPropertyElementMain], [1, 2]] as [[AudioObjectPropertyElement]] {
                let present = candidate.filter {
                    var a = Self.address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: $0)
                    return AudioObjectHasProperty(device, &a)
                }
                if present.count == candidate.count { volumeElements = present; break }
            }
            canSetVolume = !volumeElements.isEmpty && volumeElements.allSatisfy {
                var a = Self.address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: $0)
                var settable: DarwinBoolean = false
                return AudioObjectIsPropertySettable(device, &a, &settable) == noErr && settable.boolValue
            }
        }
        readVolume()
        addVolumeListener()
    }

    private func readVolume() {
        guard !volumeElements.isEmpty else { volume = nil; return }
        let values = volumeElements.compactMap { element -> Float? in
            var a = Self.address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: element)
            var v: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            return AudioObjectGetPropertyData(device, &a, 0, nil, &size, &v) == noErr ? v : nil
        }
        volume = values.isEmpty ? nil : values.reduce(0, +) / Float(values.count)
    }

    private func addVolumeListener() {
        guard !volumeElements.isEmpty else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.readVolume() }
        }
        volumeListener = block
        for element in volumeElements {
            var a = Self.address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: element)
            AudioObjectAddPropertyListenerBlock(device, &a, .main, block)
        }
    }

    private func removeVolumeListener() {
        guard let block = volumeListener, device != kAudioObjectUnknown else { volumeListener = nil; return }
        for element in volumeElements {
            var a = Self.address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: element)
            AudioObjectRemovePropertyListenerBlock(device, &a, .main, block)
        }
        volumeListener = nil
    }

    // MARK: Core Audio reads

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private static func defaultDevice() -> AudioObjectID {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr
        else { return AudioObjectID(kAudioObjectUnknown) }
        return id
    }

    private static func readName(_ device: AudioObjectID) -> String? {
        var addr = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &name) == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    private static func readTransport(_ device: AudioObjectID) -> OutputTransport {
        var addr = address(kAudioDevicePropertyTransportType)
        var raw: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &raw) == noErr else { return .other }
        return OutputTransport(raw: raw)
    }
}

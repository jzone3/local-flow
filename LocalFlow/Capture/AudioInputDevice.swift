import CoreAudio
import Foundation

/// A microphone as CoreAudio sees it. `all` lists every device with an input stream; `current` is the one
/// the user picked in Settings (or the system default when none is picked or it is unplugged).
struct AudioInputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String

    static var all: [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannelCount(id) > 0, !isPrivateAggregate(id), let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name)
        }
    }

    static var systemDefault: AudioInputDevice? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return all.first { $0.id == id }
    }

    /// The device recording will use right now.
    static var current: AudioInputDevice {
        let devices = all
        if let uid = AppSettings.shared.inputDeviceUID, let picked = devices.first(where: { $0.uid == uid }) { return picked }
        return systemDefault ?? devices.first ?? AudioInputDevice(id: 0, uid: "", name: "No microphone")
    }

    /// CoreAudio creates a hidden aggregate ("CADefaultDeviceAggregate-<pid>-0") for every app that opens the
    /// default input, including us; it has input channels but is not a microphone the user should see.
    private static func isPrivateAggregate(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport) == noErr,
              transport == kAudioDeviceTransportTypeAggregate else { return false }
        address.mSelector = kAudioAggregateDevicePropertyComposition
        var composition: CFDictionary? = nil
        size = UInt32(MemoryLayout<CFDictionary?>.size)
        let status = withUnsafeMutablePointer(to: &composition) { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0) }
        guard status == noErr, let dict = composition as? [String: Any] else { return false }
        return (dict[kAudioAggregateDeviceIsPrivateKey] as? NSNumber)?.boolValue == true
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0) }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}

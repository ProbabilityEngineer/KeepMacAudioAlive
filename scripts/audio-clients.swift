// Run: swift scripts/audio-clients.swift
// Requires macOS 14.2+ for CoreAudio's process-object properties.
import Foundation
import CoreAudio

func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                               mElement: kAudioObjectPropertyElementMain)
}

func ids(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> [AudioObjectID] {
    var property = address(selector)
    var size: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size)
    guard status == noErr else { throw NSError(domain: "CoreAudio", code: Int(status)) }
    guard size > 0 else { return [] }
    var result = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    status = AudioObjectGetPropertyData(object, &property, 0, nil, &size, &result)
    guard status == noErr else { throw NSError(domain: "CoreAudio", code: Int(status)) }
    return Array(result.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
}

func number(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    var property = address(selector)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr else { return nil }
    return value
}

func name(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
    var property = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr,
          let value else { return "unknown" }
    return value.takeRetainedValue() as String
}

if #available(macOS 14.2, *) {
    do {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let devices = try ids(system, kAudioHardwarePropertyDevices)
        let processes = try ids(system, kAudioHardwarePropertyProcessObjectList)
        for device in devices {
            let deviceName = name(device, kAudioObjectPropertyName)
            guard deviceName.localizedCaseInsensitiveContains("Anker") else { continue }
            let running = number(device, kAudioDevicePropertyDeviceIsRunningSomewhere).map(String.init) ?? "unknown"
            print("\(deviceName) — device ID \(device), running somewhere: \(running)")
            var matches = 0
            for process in processes {
                guard let used = try? ids(process, kAudioProcessPropertyDevices),
                      used.contains(device) else { continue }
                matches += 1
                let pid = number(process, kAudioProcessPropertyPID).map(String.init) ?? "unknown"
                let output = number(process, kAudioProcessPropertyIsRunningOutput).map(String.init) ?? "unknown"
                print("  PID \(pid)  output running=\(output)  \(name(process, kAudioProcessPropertyBundleID))")
            }
            if matches == 0 { print("  No process clients reported by CoreAudio.") }
        }
        if !devices.contains(where: { name($0, kAudioObjectPropertyName).localizedCaseInsensitiveContains("Anker") }) {
            print("No Anker audio device found.")
        }
    } catch {
        fputs("Could not enumerate CoreAudio clients: \(error)\n", stderr)
        exit(1)
    }
} else {
    fputs("This diagnostic requires macOS 14.2 or later.\n", stderr)
    exit(1)
}

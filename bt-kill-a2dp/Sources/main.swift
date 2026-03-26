// bt-kill-a2dp
// Releases the A2DP audio stream from a Bluetooth device so multipoint
// headphones can route audio from another device (e.g. phone).
//
// Default: switches macOS default audio output to built-in speakers via
// CoreAudio. This causes coreaudiod to send AVDTP SUSPEND to the headphones.
//
// --force: also disconnects the BT device entirely. Just switching output
// only SUSPENDs the A2DP transport (headphones still see an active Mac
// stream). Full disconnect tears down the ACL link and frees A2DP.
// NOTE: We do NOT reconnect — reconnecting always re-negotiates A2DP
// (macOS BT stack does this automatically for audio devices).

import Foundation
import IOBluetooth
import CoreAudio

// MARK: - CoreAudio helpers

func getAudioDevices() -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
    ) == noErr else { return [] }

    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var devices = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices
    ) == noErr else { return [] }
    return devices
}

func isOutputDevice(_ id: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
          size > 0 else { return false }

    let buf = UnsafeMutableRawPointer.allocate(
        byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { buf.deallocate() }
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buf) == noErr
    else { return false }

    return buf.assumingMemoryBound(to: AudioBufferList.self).pointee.mNumberBuffers > 0
}

func deviceName(_ id: AudioDeviceID) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var name: CFString? = nil
    var size = UInt32(MemoryLayout<CFString?>.size)
    let err = withUnsafeMutablePointer(to: &name) { ptr in
        AudioObjectGetPropertyData(id, &address, 0, nil, &size,
                                   UnsafeMutableRawPointer(ptr))
    }
    guard err == noErr, let result = name else { return nil }
    return result as String
}

func defaultOutputDevice() -> AudioDeviceID {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var id: AudioDeviceID = 0
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
    )
    return id
}

func setDefaultOutput(_ id: AudioDeviceID) -> Bool {
    var mutableID = id
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    return AudioObjectSetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
        UInt32(MemoryLayout<AudioDeviceID>.size), &mutableID
    ) == noErr
}

func findOutputDevice(named target: String) -> AudioDeviceID? {
    for id in getAudioDevices() {
        if isOutputDevice(id), let n = deviceName(id), n == target {
            return id
        }
    }
    return nil
}

func isDeviceRunning(_ id: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var running: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &running) == noErr
    else { return false }
    return running != 0
}

// MARK: - Argument parsing

func usage() -> Never {
    fputs("""
    Usage: bt-kill-a2dp <mac-address> [options]

    Releases the A2DP audio stream from a Bluetooth device.

    Options:
      --speakers <name>   Built-in speaker name (default: "MacBook Air Speakers")
      --force             Disconnect BT entirely to guarantee A2DP release
      --mute              Mute output after switching (avoids race with external mute)
      --status            Print device state without changing anything
      -h, --help          Show this help

    """, stderr)
    exit(1)
}

var macAddress = ""
var speakerName = "MacBook Air Speakers"
var force = false
var muteAfterSwitch = false
var statusOnly = false

do {
    let args = CommandLine.arguments
    guard args.count >= 2 else { usage() }
    if args[1] == "-h" || args[1] == "--help" { usage() }
    macAddress = args[1]

    var i = 2
    while i < args.count {
        switch args[i] {
        case "--speakers":
            i += 1
            guard i < args.count else {
                fputs("Error: --speakers requires a value\n", stderr)
                exit(1)
            }
            speakerName = args[i]
        case "--force":  force = true
        case "--mute":   muteAfterSwitch = true
        case "--status": statusOnly = true
        case "-h", "--help": usage()
        default:
            fputs("Unknown option: \(args[i])\n", stderr)
            usage()
        }
        i += 1
    }
}

// MARK: - Gather state

let btDevice = IOBluetoothDevice(addressString: macAddress)
let btConnected = btDevice?.isConnected() ?? false
let btName = btDevice?.name ?? macAddress
let btAudioID = findOutputDevice(named: btName)
let curDefault = defaultOutputDevice()
let curDefaultName = deviceName(curDefault) ?? "unknown"
let isBTDefault = btAudioID.map { $0 == curDefault } ?? false
let btRunning = btAudioID.map { isDeviceRunning($0) } ?? false

// MARK: - Status mode

if statusOnly {
    print("Device:          \(btName) (\(macAddress))")
    print("BT connected:    \(btConnected)")
    print("Audio device:    \(btAudioID != nil ? "found" : "not found")")
    print("Default output:  \(isBTDefault) (current: \(curDefaultName))")
    print("Active IO:       \(btRunning)")
    exit(0)
}

// MARK: - Step 1: Switch output to speakers

guard let speakerID = findOutputDevice(named: speakerName) else {
    fputs("Error: speaker device '\(speakerName)' not found\n", stderr)
    fputs("Available output devices:\n", stderr)
    for id in getAudioDevices() where isOutputDevice(id) {
        if let n = deviceName(id) { fputs("  - \(n)\n", stderr) }
    }
    exit(2)
}

if isBTDefault {
    guard setDefaultOutput(speakerID) else {
        fputs("Error: failed to switch default output\n", stderr)
        exit(1)
    }
    print("Switched output: '\(btName)' -> '\(speakerName)'")
} else {
    print("Output already on '\(curDefaultName)' (not \(btName))")
}

// NOTE: Mute MUST happen here, not in the calling bash script. If the bash
// script runs `osascript -e 'set volume 0'` after we return, there's a race
// where AppleScript may still see the old output device and mute the
// headphones instead of the speakers. Doing it in-process right after the
// CoreAudio switch guarantees we target the correct (speaker) device.
if muteAfterSwitch {
    // Verify the default is now the speaker before muting
    let postSwitchDefault = defaultOutputDevice()
    if postSwitchDefault == speakerID {
        var volume: Float32 = 0.0
        var volPropAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        // NOTE: Try element 0 (master), 1 (left), 2 (right). Built-in speakers
        // often only expose per-channel (1, 2), not master (0).
        for channel: UInt32 in [0, 1, 2] {
            volPropAddress.mElement = channel
            var settable: DarwinBoolean = false
            if AudioObjectIsPropertySettable(speakerID, &volPropAddress, &settable) == noErr,
               settable.boolValue {
                AudioObjectSetPropertyData(
                    speakerID, &volPropAddress, 0, nil,
                    UInt32(MemoryLayout<Float32>.size), &volume
                )
            }
        }
        print("Muted speakers")
    }
}

// MARK: - Step 2 (--force): disconnect BT to tear down A2DP transport
//
// NOTE: We disconnect and do NOT reconnect. Reconnecting always re-negotiates
// A2DP (macOS BT stack does this automatically for audio devices), which defeats
// the purpose. The calling script handles reconnection on lid open.

if force {
    guard let device = btDevice, btConnected else {
        print("BT device not connected — skipping force-release")
        exit(0)
    }

    print("Disconnecting \(btName) to release A2DP...")
    let closeErr = device.closeConnection()
    if closeErr == kIOReturnSuccess {
        print("Done — \(btName) disconnected, A2DP freed.")
    } else {
        fputs("Warning: closeConnection returned \(closeErr)\n", stderr)
    }
}

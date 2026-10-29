//
//  CoreAudioHelpers.swift
//  InHausEQ
//
//  Small, safe wrappers around Core Audio property reads.
//  None of these are real-time safe: never call them from the IOProc.
//

import Foundation
import CoreAudio
import AudioToolbox

enum CoreAudioError: Error, CustomStringConvertible {
    case status(OSStatus)
    case failed(String, OSStatus)
    case unsupportedFormat(String)
    case missingData

    var description: String {
        switch self {
        case .status(let s): return "Core Audio error \(CoreAudioError.code(s))"
        case .failed(let what, let s): return "\(what) failed: \(CoreAudioError.code(s))"
        case .unsupportedFormat(let why): return "Unsupported tap format: \(why)"
        case .missingData: return "Core Audio returned no data"
        }
    }

    /// Many Core Audio errors are four letters packed into a number, like '!dev'.
    static func code(_ status: OSStatus) -> String {
        let n = UInt32(bitPattern: status)
        let bytes = [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF),
                     UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
        if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) {
            return "'\(String(decoding: bytes, as: UTF8.self))' (\(status))"
        }
        return "\(status)"
    }
}

enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    // MARK: - Devices

    static func defaultOutputDevice() throws -> AudioDeviceID {
        let id: AudioDeviceID = try read(system, kAudioHardwarePropertyDefaultOutputDevice,
                                         initial: AudioDeviceID(kAudioObjectUnknown))
        guard id != kAudioObjectUnknown else { throw CoreAudioError.missingData }
        return id
    }

    static func deviceUID(_ id: AudioDeviceID) throws -> String {
        try readString(id, kAudioDevicePropertyDeviceUID)
    }

    static func deviceName(_ id: AudioDeviceID) -> String {
        (try? readString(id, kAudioObjectPropertyName)) ?? "Unknown"
    }

    static func nominalSampleRate(_ id: AudioDeviceID) throws -> Double {
        try read(id, kAudioDevicePropertyNominalSampleRate, initial: Float64(0))
    }

    /// Total output channels across all of the device's output streams. 0 on failure.
    static func outputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = makeAddress(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }

        let list = UnsafeMutableAudioBufferListPointer(raw.bindMemory(to: AudioBufferList.self, capacity: 1))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// The device's left/right channels as 0-based indexes. Core Audio reports them 1-based.
    static func preferredStereoChannels(_ id: AudioDeviceID) -> (left: Int, right: Int) {
        let pair = try? read(id, kAudioDevicePropertyPreferredChannelsForStereo,
                             scope: kAudioObjectPropertyScopeOutput,
                             initial: (UInt32(1), UInt32(2)))
        guard let pair, pair.0 >= 1, pair.1 >= 1 else { return (0, 1) }
        return (Int(pair.0) - 1, Int(pair.1) - 1)
    }

    /// Sample rates the device supports, e.g. [44100, 48000, 96000]. Devices that report a
    /// continuous range get the standard rates inside it.
    static func availableSampleRates(_ id: AudioDeviceID) -> [Double] {
        var address = makeAddress(kAudioDevicePropertyAvailableNominalSampleRates)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let stride = MemoryLayout<AudioValueRange>.stride
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / stride)
        let err = ranges.withUnsafeMutableBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return kAudioHardwareUnspecifiedError }
            return AudioObjectGetPropertyData(id, &address, 0, nil, &size, base)
        }
        guard err == noErr else { return [] }
        let standard: [Double] = [44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000, 705600, 768000]
        var rates = Set<Double>()
        for range in ranges.prefix(Int(size) / stride) {
            if range.mMinimum == range.mMaximum {
                rates.insert(range.mMinimum)
            } else {
                for rate in standard where rate >= range.mMinimum && rate <= range.mMaximum { rates.insert(rate) }
            }
        }
        return rates.sorted()
    }

    /// Changes the device's sample rate, the same setting as Audio MIDI Setup.
    static func setNominalSampleRate(_ id: AudioDeviceID, _ rate: Double) throws {
        var address = makeAddress(kAudioDevicePropertyNominalSampleRate)
        var value = Float64(rate)
        let err = AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Float64>.size), &value)
        guard err == noErr else { throw CoreAudioError.failed("Setting the sample rate", err) }
    }

    static func transportType(_ id: AudioDeviceID) -> UInt32? {
        try? read(id, kAudioDevicePropertyTransportType, initial: UInt32(0))
    }

    static func isBluetooth(_ id: AudioDeviceID) -> Bool {
        let type = transportType(id)
        return type == kAudioDeviceTransportTypeBluetooth || type == kAudioDeviceTransportTypeBluetoothLE
    }

    static func isAlive(_ id: AudioDeviceID) -> Bool {
        ((try? read(id, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0))) ?? 0) != 0
    }

    static func allDevices() -> [AudioDeviceID] {
        readIDList(system, kAudioHardwarePropertyDevices)
    }

    /// Destroys aggregate devices left behind by a crash. Returns how many it removed.
    static func destroyOrphanedAggregates(namePrefix: String) -> Int {
        var destroyed = 0
        for device in allDevices() where transportType(device) == kAudioDeviceTransportTypeAggregate {
            guard deviceName(device).hasPrefix(namePrefix) else { continue }
            if AudioHardwareDestroyAggregateDevice(device) == noErr { destroyed += 1 }
        }
        return destroyed
    }

    // MARK: - Taps

    static func tapFormat(_ tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        try read(tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
    }

    // MARK: - Processes

    static func processObjects() -> [AudioObjectID] {
        readIDList(system, kAudioHardwarePropertyProcessObjectList)
    }

    static func processObject(forPID pid: pid_t) -> AudioObjectID? {
        var address = makeAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifier = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(system, &address,
                                             UInt32(MemoryLayout<pid_t>.size), &qualifier,
                                             &size, &object)
        guard err == noErr, object != kAudioObjectUnknown else { return nil }
        return object
    }

    static func pid(ofProcess obj: AudioObjectID) -> pid_t? {
        try? read(obj, kAudioProcessPropertyPID, initial: pid_t(0))
    }

    static func bundleID(ofProcess obj: AudioObjectID) -> String? {
        guard let id = try? readString(obj, kAudioProcessPropertyBundleID), !id.isEmpty else { return nil }
        return id
    }

    static func isRunningOutput(_ obj: AudioObjectID) -> Bool {
        ((try? read(obj, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) ?? 0) != 0
    }

    static func isRunningInput(_ obj: AudioObjectID) -> Bool {
        ((try? read(obj, kAudioProcessPropertyIsRunningInput, initial: UInt32(0))) ?? 0) != 0
    }

    // MARK: - Generic readers

    private static func makeAddress(_ selector: AudioObjectPropertySelector,
                                    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// Reads a fixed-size value: UInt32, Float64, an ID, a plain struct.
    private static func read<T>(_ object: AudioObjectID,
                                _ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                initial: T) throws -> T {
        var address = makeAddress(selector, scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let err = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, ptr)
        }
        guard err == noErr else { throw CoreAudioError.status(err) }
        return value
    }

    /// Reads a CFString property. Core Audio hands it over retained, so take ownership exactly once.
    private static func readString(_ object: AudioObjectID,
                                   _ selector: AudioObjectPropertySelector) throws -> String {
        var address = makeAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, ptr)
        }
        guard err == noErr else { throw CoreAudioError.status(err) }
        guard let string = value?.takeRetainedValue() else { throw CoreAudioError.missingData }
        return string as String
    }

    /// Reads a variable-length list of object IDs. Empty on failure.
    private static func readIDList(_ object: AudioObjectID,
                                   _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = makeAddress(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let stride = MemoryLayout<AudioObjectID>.stride
        var ids = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: Int(size) / stride)
        let err = ids.withUnsafeMutableBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return kAudioHardwareUnspecifiedError }
            return AudioObjectGetPropertyData(object, &address, 0, nil, &size, base)
        }
        guard err == noErr else { return [] }
        return Array(ids.prefix(Int(size) / stride))
    }
}

//
//  TapPipeline.swift
//  InHausEQ
//
//  One audio path: process tap -> private aggregate device -> IOProc -> eq_process -> output.
//  Create it, call start(), call stop() (or let it deinit). The EQ engine passed in must
//  outlive the pipeline: stop the pipeline before calling eq_destroy.
//

import Foundation
import CoreAudio
import AudioToolbox
import os

final class TapPipeline {
    let name: String
    private(set) var isRunning = false

    private let tapDescription: CATapDescription
    private let outputDevice: AudioDeviceID
    private let engine: OpaquePointer

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    private let log = Logger(subsystem: "com.inhausrepair.eq", category: "TapPipeline")

    init(name: String, tapDescription: CATapDescription,
         outputDevice: AudioDeviceID, engine: OpaquePointer) {
        self.name = name
        self.tapDescription = tapDescription
        self.outputDevice = outputDevice
        self.engine = engine
    }

    deinit { stop() }

    // MARK: - Lifecycle

    func start() throws {
        guard !isRunning else { return }
        do {
            try build()
            isRunning = true
            log.info("Pipeline \(self.name, privacy: .public) running on \(CA.deviceName(self.outputDevice), privacy: .public)")
        } catch {
            log.error("Pipeline \(self.name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            stop()
            throw error
        }
    }

    /// Full teardown in the safe order. Safe to call more than once, and after a failed start.
    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let proc = procID {
                AudioDeviceStop(aggregateID, proc)
                AudioDeviceDestroyIOProcID(aggregateID, proc)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        isRunning = false
    }

    /// Changes which processes the live tap covers (the exclude list for a global tap,
    /// the include list for a per-app tap) without rebuilding anything.
    func updateTapProcesses(_ objects: [AudioObjectID]) throws {
        tapDescription.processes = objects
        guard tapID != kAudioObjectUnknown else { return }   // not running: applied on next start
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyDescription,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var ref: CATapDescription? = tapDescription
        let err = withUnsafeMutablePointer(to: &ref) { ptr in
            AudioObjectSetPropertyData(tapID, &address, 0, nil,
                                       UInt32(MemoryLayout<CATapDescription?>.stride), ptr)
        }
        try check(err, "Updating the tap's process list")
    }

    // MARK: - Setup

    private func build() throws {
        // 1. The tap.
        tapDescription.uuid = UUID()
        tapDescription.name = "InHausEQ-\(name)"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .mutedWhenTapped

        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(tapDescription, &tap), "AudioHardwareCreateProcessTap")
        tapID = tap

        // 2. Its format: we only handle 32-bit float stereo.
        let format = try CA.tapFormat(tapID)
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32,
              format.mChannelsPerFrame == 2 else {
            throw CoreAudioError.unsupportedFormat(
                "\(format.mChannelsPerFrame) ch, \(format.mBitsPerChannel)-bit, flags \(format.mFormatFlags)")
        }
        let nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0

        // 3. A private aggregate that joins the tap to the real output.
        let outputUID = try CA.deviceUID(outputDevice)
        let tapEntry: [String: Any] = [
            kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
            // Off for Bluetooth: tap and output share the Bluetooth clock, and drift
            // correction there causes a rhythmic crackle.
            kAudioSubTapDriftCompensationKey: !CA.isBluetooth(outputDevice)
        ]
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "InHausEQ-\(name)",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [tapEntry]
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate),
                  "AudioHardwareCreateAggregateDevice")
        aggregateID = aggregate

        // The aggregate can take a moment to come alive.
        var waits = 0
        while !CA.isAlive(aggregateID) && waits < 20 {
            Thread.sleep(forTimeInterval: 0.05)
            waits += 1
        }

        // 4. Configure the DSP for this device.
        let sampleRate = try CA.nominalSampleRate(aggregateID)
        eq_set_sample_rate(engine, sampleRate)
        // Taps turn the mix down by the output's stereo-pair count; put it back.
        eq_set_input_gain(engine, Float(max(1, CA.outputChannelCount(outputDevice) / 2)))
        let stereo = CA.preferredStereoChannels(outputDevice)

        // 5. The audio callback.
        let block = TapPipeline.makeBlock(engine: engine, nonInterleaved: nonInterleaved,
                                          left: stereo.left, right: stereo.right)
        var proc: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, nil, block),
                  "AudioDeviceCreateIOProcIDWithBlock")
        procID = proc
        try check(AudioDeviceStart(aggregateID, procID), "AudioDeviceStart")
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw CoreAudioError.failed(what, status) }
    }

    // MARK: - Real-time callback

    /// Runs on Core Audio's real-time thread. No allocation, locks, logging or Swift
    /// collections in here: only pointer math and one call into the C engine.
    private static func makeBlock(engine: OpaquePointer, nonInterleaved: Bool,
                                  left: Int, right: Int) -> AudioDeviceIOBlock {
        return { _, inInputData, _, outOutputData, _ in
            // a. Start from silence on every output channel.
            let outputs = UnsafeMutableAudioBufferListPointer(outOutputData)
            for buffer in outputs {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }

            // b. The tap's buffers are the LAST input buffers.
            let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            let inL: UnsafePointer<Float>
            let inR: UnsafePointer<Float>
            let inStride: Int
            let inFrames: Int
            if nonInterleaved {
                guard inputs.count >= 2 else { return }
                let lb = inputs[inputs.count - 2]
                let rb = inputs[inputs.count - 1]
                guard let l = lb.mData, let r = rb.mData else { return }
                inL = UnsafePointer(l.assumingMemoryBound(to: Float.self))
                inR = UnsafePointer(r.assumingMemoryBound(to: Float.self))
                inStride = 1
                inFrames = Int(min(lb.mDataByteSize, rb.mDataByteSize)) / 4
            } else {
                guard inputs.count >= 1 else { return }
                let b = inputs[inputs.count - 1]
                guard let d = b.mData, b.mNumberChannels > 0 else { return }
                let p = d.assumingMemoryBound(to: Float.self)
                let channels = Int(b.mNumberChannels)
                inL = UnsafePointer(p)
                inR = UnsafePointer(channels > 1 ? p + 1 : p)
                inStride = channels
                inFrames = Int(b.mDataByteSize) / (4 * channels)
            }

            // c. Find the output buffer + offset for the left and right channels.
            var outL: UnsafeMutablePointer<Float>?
            var outR: UnsafeMutablePointer<Float>?
            var lStride = 0
            var rStride = 0
            var outFrames = 0
            var firstChannel = 0
            for buffer in outputs {
                let channels = Int(buffer.mNumberChannels)
                if let d = buffer.mData, channels > 0 {
                    let p = d.assumingMemoryBound(to: Float.self)
                    if outL == nil && left >= firstChannel && left < firstChannel + channels {
                        outL = p + (left - firstChannel)
                        lStride = channels
                        outFrames = Int(buffer.mDataByteSize) / (4 * channels)
                    }
                    if outR == nil && right >= firstChannel && right < firstChannel + channels {
                        outR = p + (right - firstChannel)
                        rStride = channels
                    }
                }
                firstChannel += channels
            }
            if outL == nil || outR == nil || lStride != rStride {
                // Fallback: the first output buffer, its first two channels.
                guard let first = outputs.first, let d = first.mData, first.mNumberChannels > 0 else { return }
                let channels = Int(first.mNumberChannels)
                let p = d.assumingMemoryBound(to: Float.self)
                outL = p
                outR = channels > 1 ? p + 1 : p
                lStride = channels
                outFrames = Int(first.mDataByteSize) / (4 * channels)
            }
            guard let oL = outL, let oR = outR else { return }

            // d. Process.
            let frames = min(inFrames, outFrames)
            guard frames > 0 else { return }
            eq_process(engine, inL, inR, Int32(inStride), oL, oR, Int32(lStride), Int32(frames))
        }
    }
}

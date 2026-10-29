//
//  AudioController.swift
//  InHausEQ
//
//  Owns the EQ engine and the global pipeline, and keeps the pipeline alive through
//  output-device switches, sleep/wake, apps launching later, and calls.
//  Everything here runs on the main thread; only the IOProc inside TapPipeline does not.
//

import Foundation
import CoreAudio
import AppKit
import Observation
import os

@MainActor
@Observable
final class AudioController {
    private(set) var outputName = ""
    private(set) var outputUID = ""
    private(set) var isRunning = false
    private(set) var lastError: String?
    /// The output device's current sample rate, and the ones it supports.
    private(set) var sampleRate: Double = 0
    private(set) var availableSampleRates: [Double] = []
    /// True when "System Audio Recording" is turned off for InHaus EQ. Nothing runs until
    /// it's turned back on (a tap without permission would only produce silence).
    private(set) var needsPermission = false

    /// Called whenever audio starts on a different device than last time, including the
    /// very first start (oldUID is "" then). EQModel uses it to swap per-device settings.
    @ObservationIgnored var onOutputDeviceChanged: ((_ oldUID: String, _ newUID: String) -> Void)?
    @ObservationIgnored private var announcedUID = ""

    /// The EQ engine. Lives as long as the app; never destroyed while a pipeline uses it.
    let engine: OpaquePointer
    /// Per-app volume (M6). Apps it manages get their own pipelines.
    let appVolume: AppVolumeManager

    @ObservationIgnored private var pipeline: TapPipeline?
    @ObservationIgnored private var outputDevice = AudioDeviceID(kAudioObjectUnknown)
    @ObservationIgnored private var started = false
    @ObservationIgnored private var ownProcess: AudioObjectID?
    @ObservationIgnored private var lastBands: [EQBand] = []
    @ObservationIgnored private var lastPreampDB: Float = 0
    @ObservationIgnored private var bypassed = false
    @ObservationIgnored private var rateListener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var rateListenerDevice = AudioDeviceID(kAudioObjectUnknown)
    private let watcher: ProcessWatcher
    @ObservationIgnored private var deviceListener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var switchTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var permissionTask: Task<Void, Never>?
    private let log = Logger(subsystem: "com.inhausrepair.eq", category: "AudioController")

    init() {
        guard let engine = eq_create(48000) else {
            fatalError("InHaus EQ could not allocate its EQ engine (out of memory).")
        }
        self.engine = engine
        self.watcher = ProcessWatcher()
        self.appVolume = AppVolumeManager()
    }

    // MARK: - Start / stop

    func start() {
        guard !started else { return }
        started = true

        let removed = CA.destroyOrphanedAggregates(namePrefix: "InHausEQ-")
        if removed > 0 { log.notice("Removed \(removed) leftover aggregate device(s) from a previous run") }

        ownProcess = CA.processObject(forPID: getpid())

        appVolume.onExclusionsChanged = { [weak self] in
            self?.pushExclusions()
        }
        watcher.onTick = { [weak self] all, playing in
            self?.appVolume.update(all: all, playing: playing)
        }
        watcher.onChange = { [weak self] newlyPlaying, inCall in
            self?.processesChanged(newlyPlaying: newlyPlaying, inCall: inCall)
        }
        watcher.start()   // first tick runs now, so call exclusions are known before the first build
        addDeviceListener()
        addSystemObservers()
        startIfPermitted()
    }

    // MARK: - Permission

    /// Builds the pipelines once macOS lets us hear system audio. Asks first if the user
    /// hasn't answered the prompt yet.
    private func startIfPermitted() {
        switch AudioPermission.status() {
        case .authorized:
            rebuild(on: nil)
        case .denied:
            permissionDenied()
        case .unknown:
            AudioPermission.request { [weak self] granted in
                guard let self, self.started else { return }
                if granted { self.rebuild(on: nil) } else { self.permissionDenied() }
            }
        }
    }

    /// The panel calls this when it opens, in case permission was turned off meanwhile.
    func checkPermission() {
        guard started, !needsPermission, AudioPermission.status() == .denied else { return }
        permissionDenied()
    }

    private func permissionDenied() {
        log.notice("System audio recording permission is off")
        needsPermission = true
        switchTask?.cancel()
        pipeline?.stop()
        pipeline = nil
        appVolume.stopAll()
        isRunning = false
        lastError = nil
        watchPermission()
    }

    /// While permission is off, check every 2 seconds and start as soon as it's back on.
    private func watchPermission() {
        guard permissionTask == nil else { return }
        permissionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.started else { return }
                if AudioPermission.status() == .authorized {
                    self.needsPermission = false
                    self.permissionTask = nil
                    self.rebuild(on: nil, forceApps: true)
                    return
                }
            }
        }
    }

    func stop() {
        guard started else { return }
        started = false
        switchTask?.cancel()
        switchTask = nil
        permissionTask?.cancel()
        permissionTask = nil
        watcher.stop()
        removeDeviceListener()
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        appVolume.stopAll()
        removeRateListener()
        pipeline?.stop()
        pipeline = nil
        isRunning = false
    }

    /// Every engine whose audio the analyzer should show: the global one plus per-app ones.
    var analyzerEngines: [OpaquePointer] {
        [engine] + appVolume.engines
    }

    /// Asks the output device to switch rates. The rate listener rebuilds the pipelines
    /// once the device has actually changed.
    func setSampleRate(_ rate: Double) {
        guard outputDevice != kAudioObjectUnknown, rate > 0, rate != sampleRate else { return }
        do {
            try CA.setNominalSampleRate(outputDevice, rate)
        } catch {
            lastError = "Couldn't change the sample rate: \(error)"
            log.error("Sample rate change failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Settings (UI thread)

    func setBands(_ bands: [EQBand], preampDB: Float) {
        lastBands = bands
        lastPreampDB = preampDB
        pushBands()
    }

    func setMasterGainDB(_ db: Float) {
        eq_set_master_gain_db(engine, db)
        appVolume.setMasterDB(db)
    }

    /// EQ off = flat filters. Volume, per-app volume and the clipper keep working.
    func setBypass(_ on: Bool) {
        bypassed = on
        pushBands()
    }

    private func pushBands() {
        let bands = bypassed ? [] : lastBands
        let preamp = bypassed ? 0 : lastPreampDB
        let count = Int32(min(bands.count, Int(EQ_MAX_BANDS)))
        bands.withUnsafeBufferPointer { buffer in
            _ = eq_set_bands(engine, buffer.baseAddress, count, preamp)   // never blocks or fails
        }
        appVolume.applyEQ(bands: bands, preampDB: preamp)
    }

    // MARK: - Pipeline

    private var excludeList: [AudioObjectID] {
        var list: [AudioObjectID] = []
        if let own = ownProcess { list.append(own) }
        for process in watcher.inCall where !list.contains(process) { list.append(process) }
        for process in appVolume.excludedObjects where !list.contains(process) { list.append(process) }
        return list
    }

    /// Tears down the current pipeline and builds a fresh one (default output when nil).
    /// Per-app pipelines follow to the new device; `forceApps` rebuilds them even if the
    /// device didn't change (after sleep).
    private func rebuild(on device: AudioDeviceID?, forceApps: Bool = false) {
        pipeline?.stop()
        pipeline = nil
        do {
            let target = try device ?? CA.defaultOutputDevice()
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excludeList)
            let next = TapPipeline(name: "global", tapDescription: description,
                                   outputDevice: target, engine: engine)
            try next.start()
            pipeline = next
            outputDevice = target
            outputName = CA.deviceName(target)
            outputUID = (try? CA.deviceUID(target)) ?? ""
            lastError = nil
            isRunning = true
            sampleRate = (try? CA.nominalSampleRate(target)) ?? 0
            availableSampleRates = CA.availableSampleRates(target)
            watchSampleRate(of: target)
            appVolume.setOutputDevice(target, force: forceApps)
            if outputUID != announcedUID {
                let previous = announcedUID
                announcedUID = outputUID
                onOutputDeviceChanged?(previous, outputUID)
            }
        } catch {
            isRunning = false
            lastError = "Couldn't start audio: \(error)"
            log.error("Rebuild failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func pushExclusions() {
        guard let pipeline, pipeline.isRunning else { return }
        do {
            try pipeline.updateTapProcesses(excludeList)
        } catch {
            log.error("Tap update failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func processesChanged(newlyPlaying: Set<AudioObjectID>, inCall: Set<AudioObjectID>) {
        // Calls changed -> new exclude list. New app playing -> same list, but re-setting
        // it makes the live tap pick that app up (otherwise it can end up silent).
        pushExclusions()
    }

    // MARK: - Device switches

    private func addDeviceListener() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.scheduleSwitch(force: false, delay: .milliseconds(300)) }
        }
        let err = AudioObjectAddPropertyListenerBlock(CA.system, &address, DispatchQueue.main, block)
        if err == noErr {
            deviceListener = block
        } else {
            log.error("Couldn't watch the default output: \(CoreAudioError.code(err), privacy: .public)")
        }
    }

    private func removeDeviceListener() {
        guard let block = deviceListener else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(CA.system, &address, DispatchQueue.main, block)
        deviceListener = nil
    }

    /// Debounced: a burst of change notifications produces one switch.
    private func scheduleSwitch(force: Bool, delay: Duration) {
        switchTask?.cancel()
        switchTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            if Task.isCancelled { return }
            await self?.switchOutput(force: force)
        }
    }

    private func switchOutput(force: Bool) async {
        guard started, !needsPermission, let newDevice = try? CA.defaultOutputDevice() else { return }
        if !force && newDevice == outputDevice && pipeline?.isRunning == true { return }

        pipeline?.stop()
        pipeline = nil
        isRunning = false

        // Bluetooth devices in particular take a moment to come up.
        for _ in 0..<30 where !CA.isAlive(newDevice) {
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return }
        }

        rebuild(on: newDevice, forceApps: force)
    }

    // MARK: - Sample rate changes (from our picker or Audio MIDI Setup)

    private func watchSampleRate(of device: AudioDeviceID) {
        guard device != rateListenerDevice else { return }
        removeRateListener()
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.sampleRateChanged() }
        }
        if AudioObjectAddPropertyListenerBlock(device, &address, DispatchQueue.main, block) == noErr {
            rateListener = block
            rateListenerDevice = device
        }
    }

    private func removeRateListener() {
        guard let block = rateListener else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(rateListenerDevice, &address, DispatchQueue.main, block)
        rateListener = nil
        rateListenerDevice = AudioDeviceID(kAudioObjectUnknown)
    }

    private func sampleRateChanged() {
        guard let rate = try? CA.nominalSampleRate(outputDevice), rate != sampleRate else { return }
        sampleRate = rate
        // The EQ math depends on the rate, so rebuild everything at the new rate.
        scheduleSwitch(force: true, delay: .milliseconds(300))
    }

    // MARK: - Sleep and quit

    private func addSystemObservers() {
        let wake = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleSwitch(force: true, delay: .seconds(1)) }
        }
        let quit = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        observers = [wake, quit]
    }
}

//
//  AppVolumeManager.swift
//  InHausEQ
//
//  Per-app volume. An app you move off 100% gets its own pipeline (its own tap, EQ engine
//  and gain) and is left out of the global tap. The pipeline stays until the app quits,
//  so dragging a slider never starts and stops audio paths. Volumes are remembered
//  per app and re-applied the next time it runs.
//

import Foundation
import AppKit
import CoreAudio
import Observation
import os

@MainActor
@Observable
final class AppVolumeManager {
    struct AudioApp: Identifiable, Equatable {
        let id: String              // bundle ID of the app
        let name: String
        let icon: NSImage?
        var processObjects: [AudioObjectID]
        var isPlaying: Bool

        static func == (a: AudioApp, b: AudioApp) -> Bool {
            a.id == b.id && a.name == b.name && a.processObjects == b.processObjects && a.isPlaying == b.isPlaying
        }
    }

    /// Apps shown in the UI: playing now, or with their own pipeline.
    private(set) var apps: [AudioApp] = []
    /// Remembered volumes, bundle ID -> percent. Apps at 100% aren't stored.
    private(set) var percents: [String: Float] = [:]

    /// Called when the set of processes that must stay out of the global tap changes.
    @ObservationIgnored var onExclusionsChanged: (() -> Void)?

    private struct Identity {
        let key: String             // "" = not an app we list (daemons, our own process)
        let name: String
        let icon: NSImage?
    }

    private final class AppPipeline {
        let pipeline: TapPipeline
        let engine: OpaquePointer
        var objects: [AudioObjectID]
        init(pipeline: TapPipeline, engine: OpaquePointer, objects: [AudioObjectID]) {
            self.pipeline = pipeline
            self.engine = engine
            self.objects = objects
        }
    }

    @ObservationIgnored private var identities: [AudioObjectID: Identity] = [:]
    @ObservationIgnored private var pipelines: [String: AppPipeline] = [:]
    @ObservationIgnored private var retryAfter: [String: Date] = [:]
    @ObservationIgnored private var outputDevice = AudioDeviceID(kAudioObjectUnknown)
    @ObservationIgnored private var bands: [EQBand] = []
    @ObservationIgnored private var preampDB: Float = 0
    @ObservationIgnored private var masterDB: Float = 0
    private let log = Logger(subsystem: "com.inhausrepair.eq", category: "AppVolume")
    private static let defaultsKey = "InHausEQ.appVolumes"

    init() {
        if let saved = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: Double] {
            percents = saved.mapValues { Float($0) }
        }
    }

    // MARK: - Used by AudioController

    /// The EQ engines of the per-app pipelines (for the spectrum analyzer).
    var engines: [OpaquePointer] {
        pipelines.values.map { $0.engine }
    }

    /// Every process object currently hidden from the global tap.
    var excludedObjects: [AudioObjectID] {
        pipelines.values.flatMap { $0.objects }
    }

    /// Called every second with Core Audio's process list.
    func update(all: Set<AudioObjectID>, playing: Set<AudioObjectID>) {
        identities = identities.filter { all.contains($0.key) }
        let unknown = all.filter { identities[$0] == nil }
        if !unknown.isEmpty {
            let running = Dictionary(NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) },
                                     uniquingKeysWith: { first, _ in first })
            for object in unknown {
                identities[object] = Self.identify(object, running: running)
            }
        }

        // Group process objects by app.
        var objectsByApp: [String: [AudioObjectID]] = [:]
        var info: [String: Identity] = [:]
        var playingApps = Set<String>()
        for object in all {
            guard let identity = identities[object], !identity.key.isEmpty else { continue }
            objectsByApp[identity.key, default: []].append(object)
            info[identity.key] = identity
            if playing.contains(object) { playingApps.insert(identity.key) }
        }
        for key in objectsByApp.keys { objectsByApp[key]?.sort() }

        // Keep pipelines in step with the apps.
        var exclusionsChanged = false
        for key in pipelines.keys where objectsByApp[key] == nil {
            stopPipeline(key)               // app quit
            exclusionsChanged = true
        }
        for (key, objects) in objectsByApp {
            if let existing = pipelines[key] {
                if existing.objects != objects {   // e.g. a browser opened a new helper process
                    existing.objects = objects
                    try? existing.pipeline.updateTapProcesses(objects)
                    exclusionsChanged = true
                }
            } else if let percent = percents[key], (retryAfter[key] ?? .distantPast) < Date() {
                startPipeline(key, objects: objects, percent: percent)   // remembered volume
            }
        }
        if exclusionsChanged { onExclusionsChanged?() }

        // What the UI shows.
        let newApps: [AudioApp] = objectsByApp.compactMap { key, objects in
            let isPlaying = playingApps.contains(key)
            guard isPlaying || pipelines[key] != nil, let identity = info[key] else { return nil }
            return AudioApp(id: key, name: identity.name, icon: identity.icon,
                            processObjects: objects, isPlaying: isPlaying)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if newApps != apps { apps = newApps }
    }

    /// Moves every per-app pipeline to a new output (or rebuilds them after sleep).
    func setOutputDevice(_ device: AudioDeviceID, force: Bool = false) {
        guard device != outputDevice || force else { return }
        outputDevice = device
        let current = pipelines
        for key in current.keys { stopPipeline(key) }
        for (key, entry) in current {
            startPipeline(key, objects: entry.objects, percent: percents[key] ?? 100)
        }
        onExclusionsChanged?()
    }

    func applyEQ(bands: [EQBand], preampDB: Float) {
        self.bands = bands
        self.preampDB = preampDB
        for entry in pipelines.values { setBands(on: entry.engine) }
    }

    func setMasterDB(_ db: Float) {
        masterDB = db
        for (key, entry) in pipelines {
            eq_set_master_gain_db(entry.engine, db + Self.percentToDB(percent(for: key)))
        }
    }

    /// Stops every per-app pipeline. None start again until setOutputDevice is called.
    func stopAll() {
        for key in pipelines.keys { stopPipeline(key) }
        outputDevice = AudioDeviceID(kAudioObjectUnknown)
    }

    // MARK: - Used by the UI

    func percent(for appID: String) -> Float {
        percents[appID] ?? 100
    }

    /// 0...200%. Values within 0.5 of 100 count as 100 (not remembered).
    func setPercent(_ value: Float, for appID: String) {
        let p = min(max(value.isFinite ? value : 100, 0), 200)
        percents[appID] = abs(p - 100) < 0.5 ? nil : p
        UserDefaults.standard.set(percents.mapValues { Double($0) }, forKey: Self.defaultsKey)

        if let entry = pipelines[appID] {
            eq_set_master_gain_db(entry.engine, masterDB + Self.percentToDB(p))
        } else if percents[appID] != nil, let app = apps.first(where: { $0.id == appID }) {
            startPipeline(appID, objects: app.processObjects, percent: p)
        }
    }

    // MARK: - Pipelines

    @discardableResult
    private func startPipeline(_ key: String, objects: [AudioObjectID], percent: Float) -> Bool {
        guard outputDevice != kAudioObjectUnknown, !objects.isEmpty, let engine = eq_create(48000) else {
            return false
        }
        setBands(on: engine)
        eq_set_master_gain_db(engine, masterDB + Self.percentToDB(percent))

        let pipeline = TapPipeline(name: "app-\(key)",
                                   tapDescription: CATapDescription(stereoMixdownOfProcesses: objects),
                                   outputDevice: outputDevice, engine: engine)
        // Take the app out of the global tap first, so its audio is never doubled.
        pipelines[key] = AppPipeline(pipeline: pipeline, engine: engine, objects: objects)
        onExclusionsChanged?()
        do {
            try pipeline.start()
            retryAfter[key] = nil
            return true
        } catch {
            log.error("Per-app pipeline for \(key, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            pipelines[key] = nil
            eq_destroy(engine)
            retryAfter[key] = Date().addingTimeInterval(30)   // don't hammer a failing app
            onExclusionsChanged?()
            return false
        }
    }

    private func stopPipeline(_ key: String) {
        guard let entry = pipelines.removeValue(forKey: key) else { return }
        entry.pipeline.stop()       // the engine must outlive the running pipeline
        eq_destroy(entry.engine)
    }

    private func setBands(on engine: OpaquePointer) {
        bands.withUnsafeBufferPointer { buffer in
            _ = eq_set_bands(engine, buffer.baseAddress, Int32(min(buffer.count, Int(EQ_MAX_BANDS))), preampDB)
        }
    }

    private static func percentToDB(_ percent: Float) -> Float {
        percent <= 0 ? -60 : 20 * log10(percent / 100)
    }

    // MARK: - Which app owns a process

    private static func identify(_ object: AudioObjectID,
                                 running: [pid_t: NSRunningApplication]) -> Identity {
        let skip = Identity(key: "", name: "", icon: nil)
        guard let pid = CA.pid(ofProcess: object), pid > 0, pid != getpid(),
              let app = owningApp(of: pid, running: running),
              let bundleID = app.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier else { return skip }
        return Identity(key: bundleID, name: app.localizedName ?? bundleID, icon: app.icon)
    }

    /// The .app a process belongs to. Helper processes (Chrome, Electron, Safari's WebKit
    /// processes) are traced back to their app.
    private static func owningApp(of pid: pid_t,
                                  running: [pid_t: NSRunningApplication]) -> NSRunningApplication? {
        func isApp(_ app: NSRunningApplication?) -> Bool { app?.bundleURL?.pathExtension == "app" }

        if isApp(running[pid]) { return running[pid] }
        if let responsible = responsiblePID(for: pid), isApp(running[responsible]) { return running[responsible] }

        var current = pid
        var visited = Set<pid_t>()
        while current > 1, !visited.contains(current) {
            visited.insert(current)
            if isApp(running[current]) { return running[current] }
            guard let parent = parentPID(of: current), parent != current else { break }
            current = parent
        }
        return nil
    }

    private typealias ResponsibilityFunc = @convention(c) (pid_t) -> pid_t

    /// What Activity Monitor uses to attribute XPC services to their app (not public API,
    /// looked up at runtime; if it's ever missing we fall back to the parent-process walk).
    private static let responsibilityFunc: ResponsibilityFunc? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                                 "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsibilityFunc.self)
    }()

    private static func responsiblePID(for pid: pid_t) -> pid_t? {
        guard let function = responsibilityFunc else { return nil }
        let responsible = function(pid)
        return responsible > 0 && responsible != pid ? responsible : nil
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 ? parent : nil
    }
}

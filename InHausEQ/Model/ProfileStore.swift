//
//  ProfileStore.swift
//  InHausEQ
//
//  Saves EQ settings per output device in
//  ~/Library/Application Support/InHausEQ/profiles.json
//

import Foundation
import AppKit
import os

struct DeviceProfile: Codable, Equatable {
    var deviceName: String
    var gains: [Float]
    var preampDB: Float
    var masterPercent: Float
    var headphone: HeadphoneProfile?

    static let flat = DeviceProfile(deviceName: "", gains: Array(repeating: 0, count: 10),
                                    preampDB: 0, masterPercent: 100, headphone: nil)
}

@MainActor
final class ProfileStore {
    private var profiles: [String: DeviceProfile] = [:]
    private var saveTask: Task<Void, Never>?
    private var quitObserver: NSObjectProtocol?
    private let fileURL: URL
    private let log = Logger(subsystem: "com.inhausrepair.eq", category: "ProfileStore")

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        fileURL = base.appendingPathComponent("InHausEQ", isDirectory: true)
            .appendingPathComponent("profiles.json")
        load()
        quitObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    func profile(forDeviceUID uid: String) -> DeviceProfile? {
        profiles[uid]
    }

    /// Remembers the profile now and writes the file about a second later.
    func save(_ profile: DeviceProfile, forDeviceUID uid: String) {
        guard !uid.isEmpty else { return }
        profiles[uid] = profile
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
            self?.write()
        }
    }

    /// Writes immediately (device switch, quit).
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        write()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            profiles = try JSONDecoder().decode([String: DeviceProfile].self, from: data)
        } catch {
            // Keep the broken file for inspection and start fresh rather than crash.
            log.error("profiles.json unreadable, starting fresh: \(String(describing: error), privacy: .public)")
            let corrupt = fileURL.deletingLastPathComponent().appendingPathComponent("profiles.corrupt.json")
            try? FileManager.default.removeItem(at: corrupt)
            try? FileManager.default.moveItem(at: fileURL, to: corrupt)
            profiles = [:]
        }
    }

    private func write() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(profiles).write(to: fileURL, options: .atomic)
        } catch {
            log.error("Couldn't save profiles: \(String(describing: error), privacy: .public)")
        }
    }
}

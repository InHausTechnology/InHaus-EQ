//
//  EQModel.swift
//  InHausEQ
//
//  What the user has set: 10 graphic-EQ bands, preamp, master volume, bypass, and an
//  optional headphone profile. Every change goes straight to the AudioController and is
//  saved for the current output device, so each device keeps its own settings.
//

import Foundation
import Observation

/// One filter from a headphone correction profile (AutoEQ ParametricEQ.txt).
struct HeadphoneFilter: Codable, Equatable {
    var type: Int32       // EQ_PEAK / EQ_LOWSHELF / EQ_HIGHSHELF raw value
    var freqHz: Float
    var gainDB: Float
    var q: Float
}

struct HeadphoneProfile: Codable, Equatable {
    var name: String
    var preampDB: Float
    var filters: [HeadphoneFilter]
}

@MainActor
@Observable
final class EQModel {
    static let frequencies: [Float] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let labels = ["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
    static let gainRange: ClosedRange<Float> = -12...12
    static let preampRange: ClosedRange<Float> = -12...6
    static let masterRange: ClosedRange<Float> = 0...400
    static let bandQ: Float = 1.41

    var gains: [Float] = Array(repeating: 0, count: 10) { didSet { changed(bands: true) } }
    var preampDB: Float = 0 { didSet { changed(bands: true) } }
    var masterPercent: Float = 100 { didSet { changed(master: true) } }
    var bypass = false { didSet { audio.setBypass(bypass) } }
    var headphone: HeadphoneProfile? = nil { didSet { changed(bands: true) } }

    /// The device these settings belong to.
    private(set) var deviceName = ""
    @ObservationIgnored private var deviceUID = ""
    @ObservationIgnored private var applying = false

    private let audio: AudioController
    private let store: ProfileStore

    init(audio: AudioController) {
        self.audio = audio
        self.store = ProfileStore()
        pushBands()
        pushMaster()
        audio.setBypass(bypass)
        audio.onOutputDeviceChanged = { [weak self] oldUID, newUID in
            self?.outputDeviceChanged(from: oldUID, to: newUID)
        }
    }

    /// The full filter chain the engine runs: headphone correction first, then the 10 bands.
    func chain() -> (bands: [EQBand], preampDB: Float) {
        var bands: [EQBand] = []
        if let profile = headphone {
            for f in profile.filters.prefix(AutoEQParser.maxFilters) {
                bands.append(EQBand(type: f.type, freqHz: f.freqHz, gainDB: f.gainDB, q: f.q, enabled: 1))
            }
        }
        for (i, gain) in gains.enumerated() where i < Self.frequencies.count {
            bands.append(EQBand(type: Int32(EQ_PEAK.rawValue), freqHz: Self.frequencies[i],
                                gainDB: gain, q: Self.bandQ, enabled: gain == 0 ? 0 : 1))
        }
        return (bands, (headphone?.preampDB ?? 0) + preampDB)
    }

    /// Master volume as dB. 100% = 0 dB, 200% = +6 dB, 400% = +12 dB.
    var masterDB: Float {
        guard masterPercent > 0 else { return -60 }
        return min(max(20 * log10(masterPercent / 100), -60), 12)
    }

    /// Flattens the 10 bands and preamp. Leaves master volume and the headphone profile alone.
    func reset() {
        apply { model in
            model.gains = Array(repeating: 0, count: Self.frequencies.count)
            model.preampDB = 0
        }
    }

    // MARK: - Per-device profiles

    func snapshot() -> DeviceProfile {
        DeviceProfile(deviceName: deviceName, gains: gains, preampDB: preampDB,
                      masterPercent: masterPercent, headphone: headphone)
    }

    /// Loads a whole profile at once, pushing to the engine once instead of per field.
    func apply(_ profile: DeviceProfile) {
        apply { model in
            model.gains = profile.gains.count == Self.frequencies.count
                ? profile.gains.map { Self.clamp($0, Self.gainRange) }
                : Array(repeating: 0, count: Self.frequencies.count)
            model.preampDB = Self.clamp(profile.preampDB, Self.preampRange)
            model.masterPercent = profile.masterPercent.isFinite
                ? Self.clamp(profile.masterPercent, Self.masterRange) : 100
            model.headphone = profile.headphone
        }
    }

    private func outputDeviceChanged(from oldUID: String, to newUID: String) {
        if !oldUID.isEmpty {
            store.save(snapshot(), forDeviceUID: oldUID)
            store.flush()
        }
        deviceUID = newUID
        deviceName = audio.outputName
        var profile = store.profile(forDeviceUID: newUID) ?? .flat
        profile.deviceName = audio.outputName
        apply(profile)
    }

    // MARK: - Private

    private func apply(_ changes: (EQModel) -> Void) {
        applying = true
        changes(self)
        applying = false
        pushBands()
        pushMaster()
        persist()
    }

    private func changed(bands: Bool = false, master: Bool = false) {
        guard !applying else { return }
        if bands { pushBands() }
        if master { pushMaster() }
        persist()
    }

    private func persist() {
        guard !deviceUID.isEmpty else { return }
        store.save(snapshot(), forDeviceUID: deviceUID)
    }

    private func pushBands() {
        let c = chain()
        audio.setBands(c.bands, preampDB: c.preampDB)
    }

    private func pushMaster() {
        audio.setMasterGainDB(masterDB)
    }

    private static func clamp(_ v: Float, _ range: ClosedRange<Float>) -> Float {
        guard v.isFinite else { return 0 }
        return min(max(v, range.lowerBound), range.upperBound)
    }
}

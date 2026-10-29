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
    /// Picking (or clearing) a headphone profile starts fresh: your slider and preamp
    /// changes are cleared, so the sliders show exactly that profile.
    var headphone: HeadphoneProfile? = nil {
        didSet {
            guard !applying else { return }
            apply { model in
                model.gains = Array(repeating: 0, count: Self.frequencies.count)
                model.preampDB = 0
            }
        }
    }

    /// True once you've moved any slider or the preamp away from where the profile put them.
    var isAdjusted: Bool {
        gains.contains { $0 != 0 } || preampDB != 0
    }

    /// What to call the current headphone setting: the profile's name, or "Custom" once
    /// you've changed it. nil without a profile.
    var headphoneTitle: String? {
        guard let profile = headphone else { return nil }
        return isAdjusted ? "Custom" : profile.name
    }

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

    // MARK: - What the sliders show
    //
    // With a headphone profile on, the sliders start at the correction: slider i shows the
    // correction at its frequency plus your own adjustment (gains[i]), and the preamp slider
    // shows the profile's preamp plus yours. The correction's exact filters keep running;
    // moving a slider only changes your adjustment. Without a profile, correction is 0.

    /// The headphone correction's filters at each slider's frequency, in dB (preamp not
    /// included; that's on the preamp slider). All zeros without a profile.
    func correctionAtBands() -> [Float] {
        guard let profile = headphone, !profile.filters.isEmpty else {
            return Array(repeating: 0, count: Self.frequencies.count)
        }
        let filters = profile.filters.prefix(AutoEQParser.maxFilters).map {
            EQBand(type: $0.type, freqHz: $0.freqHz, gainDB: $0.gainDB, q: $0.q, enabled: 1)
        }
        let rate = audio.sampleRate > 0 ? audio.sampleRate : 48000
        return filters.withUnsafeBufferPointer { buffer in
            Self.frequencies.map { hz in
                Float(eq_response_db(buffer.baseAddress, Int32(buffer.count), 0, rate, Double(hz)))
            }
        }
    }

    /// The headphone profile's preamp (0 without one).
    var correctionPreampDB: Float { headphone?.preampDB ?? 0 }

    /// Your adjustment for a slider showing `shown` when the correction there is `base`.
    /// Landing within a quarter dB of the correction counts as "no adjustment".
    static func adjustment(showing shown: Float, base: Float) -> Float {
        let difference = shown - base
        guard difference.isFinite, abs(difference) >= 0.25 else { return 0 }
        return min(max(difference, adjustRange.lowerBound), adjustRange.upperBound)
    }

    /// How far your own adjustments can go (wider than the sliders, since they sit on top
    /// of a correction that may already be well above or below 0).
    static let adjustRange: ClosedRange<Float> = -24...24

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
                ? profile.gains.map { Self.clamp($0, Self.adjustRange) }
                : Array(repeating: 0, count: Self.frequencies.count)
            model.preampDB = Self.clamp(profile.preampDB, Self.adjustRange)
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

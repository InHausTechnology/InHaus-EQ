//
//  SpectrumAnalyzer.swift
//  InHausEQ
//
//  One shared analyzer for the whole app. It runs its own loop (30 fps while a graph is
//  on screen, 20 fps for the menu bar icon alone, a slow idle check when nothing's
//  playing) and publishes fresh levels; every view that reads them redraws on its own.
//  The FFT itself runs in C (eq_spectrum).
//

import Foundation
import Observation

@MainActor
@Observable
final class SpectrumAnalyzer {
    static let points = 160
    static let minHz = 20.0
    static let maxHz = 20000.0
    static let floorDB: Float = -120
    static let iconBars = 7
    /// Tilt so typical music looks roughly level (most analyzers do this).
    static let tiltPerOctave: Float = 4.5

    /// Smoothed levels in dBFS, one per log-spaced point from minHz to maxHz.
    private(set) var after = [Float](repeating: SpectrumAnalyzer.floorDB, count: SpectrumAnalyzer.points)
    private(set) var before = [Float](repeating: SpectrumAnalyzer.floorDB, count: SpectrumAnalyzer.points)
    /// False when no engine has delivered audio for a moment (paused or stopped).
    private(set) var isLive = false
    /// 0...1 bar heights for the menu bar icon.
    private(set) var iconLevels = [Float](repeating: 0, count: SpectrumAnalyzer.iconBars)
    /// Bumps every update, so views always see a change.
    private(set) var frame = 0

    /// Show the live visualizer in the menu bar icon.
    var iconEnabled: Bool = (UserDefaults.standard.object(forKey: "InHausEQ.liveIcon") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(iconEnabled, forKey: "InHausEQ.liveIcon") }
    }

    private let engines: @MainActor () -> [OpaquePointer]
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var lastPositions: [OpaquePointer: (position: UInt32, changedAt: Date)] = [:]
    @ObservationIgnored private var scratch = [Float](repeating: SpectrumAnalyzer.floorDB, count: SpectrumAnalyzer.points)
    @ObservationIgnored private var lastUpdate = Date()

    /// Rises quickly, falls at this many dB per second (like a real meter).
    private let releaseDBPerSecond: Float = 48

    init(engines: @escaping @MainActor () -> [OpaquePointer]) {
        self.engines = engines
        loop = Task { [weak self] in
            while !Task.isCancelled {
                let wait = self?.tick() ?? 1000
                try? await Task.sleep(for: .milliseconds(wait))
            }
        }
    }

    /// Graphs call these from onAppear / onDisappear so the loop runs at full speed only
    /// while someone is looking.
    func addViewer() { viewers += 1 }
    func removeViewer() { viewers = max(0, viewers - 1) }

    // MARK: - Loop

    /// One update. Returns how long to wait before the next, in milliseconds.
    private func tick() -> Int {
        let wantsGraph = viewers > 0
        guard wantsGraph || iconEnabled else {
            if isLive { isLive = false }
            return 500
        }
        update(includeBefore: wantsGraph)   // the icon only needs the after-EQ levels
        if iconEnabled { updateIcon() }
        frame &+= 1
        if !isLive { return 250 }            // nothing playing: just check a few times a second
        return wantsGraph ? 33 : 50
    }

    private func update(includeBefore: Bool) {
        let now = Date()
        let dt = Float(min(max(now.timeIntervalSince(lastUpdate), 0), 0.25))
        lastUpdate = now

        var powerAfter = [Double](repeating: 0, count: Self.points)
        var powerBefore = [Double](repeating: 0, count: Self.points)
        var anyLive = false
        var seen = Set<OpaquePointer>()

        for engine in engines() {
            seen.insert(engine)
            let position = eq_scope_position(engine)
            if let last = lastPositions[engine], last.position == position {
                if now.timeIntervalSince(last.changedAt) > 0.3 { continue }   // this engine went quiet
            } else {
                lastPositions[engine] = (position, now)
            }
            anyLive = true
            accumulate(engine: engine, post: 1, into: &powerAfter)
            if includeBefore { accumulate(engine: engine, post: 0, into: &powerBefore) }
        }
        lastPositions = lastPositions.filter { seen.contains($0.key) }
        if isLive != anyLive { isLive = anyLive }

        let fall = releaseDBPerSecond * dt
        var newAfter = after
        var newBefore = before
        for i in 0..<Self.points {
            newAfter[i] = ballistics(current: newAfter[i], target: Self.toDB(powerAfter[i]), fall: fall)
            newBefore[i] = ballistics(current: newBefore[i], target: Self.toDB(powerBefore[i]), fall: fall)
        }
        after = newAfter
        before = newBefore
    }

    private func updateIcon() {
        guard isLive else {
            if iconLevels.contains(where: { $0 > 0 }) {
                iconLevels = [Float](repeating: 0, count: Self.iconBars)
            }
            return
        }
        var levels = [Float](repeating: 0, count: Self.iconBars)
        for bar in 0..<Self.iconBars {
            let lo = bar * Self.points / Self.iconBars
            let hi = (bar + 1) * Self.points / Self.iconBars
            var loudest = Self.floorDB
            for i in lo..<hi { loudest = max(loudest, Self.tilted(after[i], index: i)) }
            levels[bar] = min(max((loudest + 66) / 54, 0), 1)   // -66...-12 dB -> empty...full
        }
        iconLevels = levels
    }

    // MARK: - Helpers

    static func frequency(atIndex i: Int) -> Double {
        minHz * pow(maxHz / minHz, Double(i) / Double(points - 1))
    }

    static func tilted(_ db: Float, index i: Int) -> Float {
        db + tiltPerOctave * Float(log2(frequency(atIndex: i) / 1000))
    }

    private func accumulate(engine: OpaquePointer, post: Int32, into power: inout [Double]) {
        let ok = scratch.withUnsafeMutableBufferPointer { buffer in
            eq_spectrum(engine, post, Self.minHz, Self.maxHz, buffer.baseAddress, Int32(buffer.count))
        }
        guard ok == 1 else { return }
        for i in 0..<Self.points {
            power[i] += pow(10, Double(scratch[i]) / 10)   // add as power: separate streams mix
        }
    }

    private func ballistics(current: Float, target: Float, fall: Float) -> Float {
        if target >= current {
            return current + (target - current) * 0.6       // fast attack, a touch of smoothing
        }
        return max(target, current - fall)                   // steady release
    }

    private static func toDB(_ power: Double) -> Float {
        guard power > 1e-12 else { return floorDB }
        return max(Float(10 * log10(power)), floorDB)
    }
}

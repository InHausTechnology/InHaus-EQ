//
//  SampleRateMenu.swift
//  InHausEQ
//
//  The output sample-rate menu, used in the EQ window and the menu bar panel. It always
//  lists the standard rates up to 192 kHz (plus anything higher the output supports);
//  rates the current output can't run at are grayed out.
//

import SwiftUI
import Foundation

struct SampleRateMenu: View {
    let audio: AudioController

    /// Always listed, so you can see the full range even when this output can't do it all.
    static let standardRates: [Double] = [44100, 48000, 88200, 96000, 176400, 192000]

    var body: some View {
        let supported = Set(audio.availableSampleRates)
        let current = audio.sampleRate
        let rates = Self.rates(supported: supported, current: current)

        Menu {
            ForEach(rates, id: \.self) { rate in
                Toggle(Self.formatRate(rate), isOn: Binding(
                    get: { rate == current },
                    set: { on in if on { audio.setSampleRate(rate) } }
                ))
                .disabled(!supported.contains(rate))
            }
            if rates.contains(where: { !supported.contains($0) }) {
                Divider()
                Text("Grayed out: not supported by \(audio.outputName)")
            }
        } label: {
            Text(current > 0 ? Self.formatRate(current) : "–")
                .monospacedDigit()
        }
        .fixedSize()
        .disabled(!audio.isRunning)
        .help("The output's sample rate, the same setting as Audio MIDI Setup")
    }

    static func rates(supported: Set<Double>, current: Double) -> [Double] {
        var all = Set(standardRates).union(supported)
        if current > 0 { all.insert(current) }
        return all.sorted()
    }

    /// 44100 -> "44.1 kHz", 96000 -> "96 kHz"
    static func formatRate(_ rate: Double) -> String {
        let khz = rate / 1000
        return khz == khz.rounded() ? "\(Int(khz)) kHz" : String(format: "%.1f kHz", khz)
    }
}

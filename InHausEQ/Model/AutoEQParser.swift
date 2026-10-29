//
//  AutoEQParser.swift
//  InHausEQ
//
//  Reads AutoEQ's "ParametricEQ.txt" (EqualizerAPO format):
//      Preamp: -6.4 dB
//      Filter 1: ON LSC Fc 105 Hz Gain 6.5 dB Q 0.70
//      Filter 2: ON PK Fc 3100 Hz Gain -3.2 dB Q 1.95
//

import Foundation

enum AutoEQParser {
    enum ParseError: LocalizedError {
        case noFilters

        var errorDescription: String? {
            "No EQ filters found. Use AutoEQ's ParametricEQ.txt (the EqualizerAPO format)."
        }
    }

    static let maxFilters = 10

    static func parse(_ text: String, name: String) throws -> HeadphoneProfile {
        var preamp: Float = 0
        var filters: [HeadphoneFilter] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == ":" }).map(String.init)
            guard let first = tokens.first?.lowercased() else { continue }

            if first == "preamp" {
                if let value = tokens.dropFirst().compactMap({ Float($0) }).first, value.isFinite {
                    preamp = clamp(value, -30, 10)
                }
            } else if first == "filter", filters.count < maxFilters, let filter = parseFilter(tokens) {
                filters.append(filter)
            }
        }

        guard !filters.isEmpty else { throw ParseError.noFilters }
        return HeadphoneProfile(name: name, preampDB: preamp, filters: filters)
    }

    /// Parses the sample from the top of this file. Prints and returns the result.
    @discardableResult
    static func selfTest() -> Bool {
        let sample = """
        Preamp: -6.4 dB
        Filter 1: ON LSC Fc 105 Hz Gain 6.5 dB Q 0.70
        Filter 2: ON PK Fc 3100 Hz Gain -3.2 dB Q 1.95
        Filter 3: OFF PK Fc 8000 Hz Gain 2.0 dB Q 1.00
        """
        let ok: Bool
        if let p = try? parse(sample, name: "Test") {
            ok = p.filters.count == 2 && abs(p.preampDB + 6.4) < 0.001
                && p.filters[0].type == Int32(EQ_LOWSHELF.rawValue)
                && abs(p.filters[1].freqHz - 3100) < 0.001
        } else {
            ok = false
        }
        print("AutoEQParser self-test: \(ok ? "PASS" : "FAIL")")
        return ok
    }

    // MARK: - Private

    private static func parseFilter(_ tokens: [String]) -> HeadphoneFilter? {
        let upper = tokens.map { $0.uppercased() }
        guard upper.contains("ON") else { return nil }   // filters marked OFF are skipped

        let type: EQFilterType
        if upper.contains("PK") || upper.contains("PEQ") {
            type = EQ_PEAK
        } else if upper.contains("LSC") || upper.contains("LS") {
            type = EQ_LOWSHELF
        } else if upper.contains("HSC") || upper.contains("HS") {
            type = EQ_HIGHSHELF
        } else {
            return nil   // low-pass, high-pass etc. aren't supported
        }

        guard let fc = number(after: "FC", upper: upper, tokens: tokens),
              let gain = number(after: "GAIN", upper: upper, tokens: tokens),
              let q = number(after: "Q", upper: upper, tokens: tokens) else { return nil }

        return HeadphoneFilter(type: Int32(type.rawValue),
                               freqHz: clamp(fc, 20, 20000),
                               gainDB: clamp(gain, -20, 20),
                               q: clamp(q, 0.1, 10))
    }

    private static func number(after key: String, upper: [String], tokens: [String]) -> Float? {
        guard let i = upper.firstIndex(of: key), i + 1 < tokens.count,
              let value = Float(tokens[i + 1]), value.isFinite else { return nil }
        return value
    }

    private static func clamp(_ v: Float, _ lo: Float, _ hi: Float) -> Float {
        min(max(v, lo), hi)
    }
}

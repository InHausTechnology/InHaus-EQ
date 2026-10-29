//
//  EQWindow.swift
//  InHausEQ
//
//  The main equalizer window: response curve, 10 faders, preamp, on/off and reset.
//

import SwiftUI
import AppKit
import Foundation
import UniformTypeIdentifiers

struct EQWindowView: View {
    @Bindable var model: EQModel
    let audio: AudioController
    let catalog: AutoEQCatalog
    let analyzer: SpectrumAnalyzer
    @State private var importing = false
    @State private var searching = false
    @State private var importError: String?

    var body: some View {
        let chain = model.chain()
        VStack(alignment: .leading, spacing: 16) {
            header
            if audio.needsPermission {
                PermissionBanner()
            }
            ResponseCurveView(bands: chain.bands, preampDB: chain.preampDB,
                              sampleRate: audio.sampleRate, height: 200,
                              analyzer: analyzer)
            faders
            Divider()
            preampRow
            headphoneRow
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 540, alignment: .top)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("InHaus EQ")
                    .font(.title2.weight(.semibold))
                Text(audio.needsPermission ? "Needs permission to hear system audio"
                     : (audio.isRunning ? audio.outputName : (audio.lastError ?? "Not running")))
                    .font(.callout)
                    .foregroundStyle(audio.lastError == nil ? Color.secondary : Color.red)
                    .lineLimit(2)
            }
            Spacer()
            HStack(spacing: 6) {
                Text("Sample rate")
                    .foregroundStyle(.secondary)
                SampleRateMenu(audio: audio)
            }
            Toggle("EQ on", isOn: Binding(get: { !model.bypass }, set: { model.bypass = !$0 }))
                .toggleStyle(.switch)
            Button("Reset") { model.reset() }
                .help("Set every band and the preamp back to 0 dB")
        }
    }

    private var faders: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(EQModel.frequencies.indices, id: \.self) { i in
                VStack(spacing: 6) {
                    Text(Self.format(model.gains[i]))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(model.gains[i] == 0 ? Color.secondary : Color.primary)
                    VerticalFader(value: $model.gains[i], range: EQModel.gainRange,
                                  label: "\(EQModel.labels[i]) hertz")
                    Text(EQModel.labels[i])
                        .font(.caption.weight(.medium))
                        .onTapGesture(count: 2) { model.gains[i] = 0 }
                        .help("Double-click to reset this band")
                }
                .frame(maxWidth: .infinity)
            }
        }
        .disabled(model.bypass)
        .opacity(model.bypass ? 0.5 : 1)
    }

    private var preampRow: some View {
        HStack(spacing: 12) {
            Text("Preamp")
                .frame(width: 64, alignment: .leading)
            Slider(value: $model.preampDB, in: EQModel.preampRange)
            Text(String(format: "%+.1f dB", model.preampDB))
                .font(.callout.monospacedDigit())
                .frame(width: 70, alignment: .trailing)
                .onTapGesture(count: 2) { model.preampDB = 0 }
        }
        .help("Turn this down if big boosts start to distort")
    }

    private var headphoneRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "headphones")
                    .foregroundStyle(.secondary)
                if let profile = model.headphone {
                    Text(profile.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("No headphone profile")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.headphone != nil {
                    Button("Clear") { model.headphone = nil }
                }
                Button("Find Headphones…") { searching = true }
                    .help("Search AutoEQ's database and download a correction profile")
                Button("From File…") { importing = true }
                    .help("Load a ParametricEQ.txt you already have (EqualizerAPO format)")
            }
            if let importError {
                Text(importError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Text(footnote)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .font(.callout)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .text]) { result in
            handleImport(result)
        }
        .sheet(isPresented: $searching) {
            AutoEQSearchView(catalog: catalog) { profile in
                model.headphone = profile
                importError = nil
            }
        }
    }

    private var footnote: String {
        let device = model.deviceName.isEmpty ? "this device" : model.deviceName
        if let profile = model.headphone {
            let preamp = String(format: "%+.1f", profile.preampDB)
            return "\(profile.filters.count) correction filters, preamp \(preamp) dB. Saved for \(device)."
        }
        return "Settings are saved for \(device). Each output keeps its own."
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            importError = error.localizedDescription
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                model.headphone = try AutoEQParser.parse(text, name: Self.profileName(from: url))
                importError = nil
            } catch {
                importError = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    /// "Sennheiser HD 660S2 ParametricEQ.txt" -> "Sennheiser HD 660S2"
    private static func profileName(from url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        for suffix in [" ParametricEQ", "ParametricEQ", " FixedBandEQ"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Imported profile" : name
    }

    private static func format(_ db: Float) -> String {
        abs(db) < 0.05 ? "0" : String(format: "%+.1f", db)
    }
}

/// A vertical fader: drag or click anywhere on it. VoiceOver sees a normal slider.
struct VerticalFader: View {
    @Binding var value: Float
    let range: ClosedRange<Float>
    var step: Float = 0.5
    var label: String = ""

    private static let pad: CGFloat = 8          // room for the thumb at the ends
    private static let thumbSize: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let track = max(geo.size.height - Self.pad * 2, 1)
            let span = range.upperBound - range.lowerBound
            let thumbY = Self.pad + track * CGFloat(1 - (value - range.lowerBound) / span)
            let zeroY = Self.pad + track * CGFloat(1 - (0 - range.lowerBound) / span)

            ZStack(alignment: .top) {
                Capsule()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 4, height: track)
                    .offset(y: Self.pad)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 4, height: abs(thumbY - zeroY))
                    .offset(y: min(thumbY, zeroY))
                Rectangle()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 12, height: 1)
                    .offset(y: zeroY)
                Circle()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2))
                    .frame(width: Self.thumbSize, height: Self.thumbSize)
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                    .offset(y: thumbY - Self.thumbSize / 2)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let fraction = 1 - Float(min(max((drag.location.y - Self.pad) / track, 0), 1))
                        let raw = range.lowerBound + fraction * span
                        let snapped = (raw / step).rounded() * step
                        value = min(max(snapped, range.lowerBound), range.upperBound)
                    }
            )
        }
        .frame(width: 28, height: 170)
        .accessibilityRepresentation {
            Slider(value: $value, in: range, step: step) { Text(label) }
        }
    }
}

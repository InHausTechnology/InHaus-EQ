//
//  MenuBarView.swift
//  InHausEQ
//
//  The panel that drops down from the menu bar icon.
//

import SwiftUI
import Foundation
import AppKit

struct MenuBarView: View {
    @Bindable var model: EQModel
    let audio: AudioController
    let catalog: AutoEQCatalog
    @Bindable var analyzer: SpectrumAnalyzer
    @Environment(\.openWindow) private var openWindow
    @State private var launchAtLogin = false
    @State private var loginError: String?

    var body: some View {
        let chain = model.chain()
        VStack(alignment: .leading, spacing: 12) {
            // Title, device, on/off
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("InHaus EQ").font(.headline)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Toggle("EQ on", isOn: Binding(get: { !model.bypass }, set: { model.bypass = !$0 }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .help(model.bypass ? "EQ is off" : "EQ is on")
            }

            if audio.needsPermission {
                PermissionBanner()
            }

            ResponseCurveView(bands: chain.bands, preampDB: chain.preampDB, sampleRate: audio.sampleRate,
                              height: 64, showsLabels: false, analyzer: analyzer)
                .opacity(model.bypass ? 0.4 : 1)

            // Master volume
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Volume")
                    Spacer()
                    Button("\(Int(model.masterPercent.rounded()))%") { model.masterPercent = 100 }
                        .buttonStyle(.plain)
                        .monospacedDigit()
                        .foregroundStyle(model.masterPercent > 100 ? Color.orange : Color.secondary)
                        .help("Click to reset to 100%")
                }
                .font(.callout)
                Slider(value: masterBinding, in: EQModel.masterRange)
                if model.masterPercent > 100 {
                    Text("Boosting past your Mac's max volume")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("Sample rate")
                Spacer()
                SampleRateMenu(audio: audio)
                    .controlSize(.small)
            }
            .font(.callout)

            Divider()

            AppVolumeList(manager: audio.appVolume)

            Divider()

            HeadphonePicker(model: model, catalog: catalog)

            if let error = audio.lastError ?? loginError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Button("Open Equalizer…") { openEqualizer() }
                Spacer()
                settingsMenu
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear {
            audio.checkPermission()
            launchAtLogin = LaunchAtLogin.isEnabled
        }
    }

    private var statusText: String {
        if audio.needsPermission { return "Needs permission" }
        return audio.isRunning ? audio.outputName : "Not running"
    }

    private var settingsMenu: some View {
        Menu {
            Toggle("Launch at Login", isOn: Binding(
                get: { launchAtLogin },
                set: { on in
                    loginError = LaunchAtLogin.set(on)
                    launchAtLogin = LaunchAtLogin.isEnabled
                }
            ))
            Toggle("Live Menu Bar Icon", isOn: $analyzer.iconEnabled)
            Divider()
            Button("About InHaus EQ") { AboutPanel.show() }
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Settings")
    }

    /// Snaps to 100% when you drag close to it, so "normal" is easy to land on.
    private var masterBinding: Binding<Float> {
        Binding(
            get: { model.masterPercent },
            set: { newValue in model.masterPercent = abs(newValue - 100) < 4 ? 100 : newValue }
        )
    }

    private func openEqualizer() {
        openWindow(id: "eq")
        NSApp.activate()
    }
}

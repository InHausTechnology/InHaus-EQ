//
//  InHausEQApp.swift
//  InHausEQ
//
//  Created by Peyton on 10/27/26.
//
//  A menu bar app (no Dock icon: LSUIElement in Info.plist) with one equalizer window.
//

import SwiftUI

@main
struct InHausEQApp: App {
    @State private var audio: AudioController
    @State private var model: EQModel
    @State private var catalog = AutoEQCatalog()
    @State private var analyzer: SpectrumAnalyzer

    init() {
        #if DEBUG
        _ = eq_selftest()           // console: "eq_selftest: 6/6 passed"
        AutoEQParser.selfTest()     // console: "AutoEQParser self-test: PASS"
        #endif
        let audio = AudioController()
        _audio = State(initialValue: audio)
        _model = State(initialValue: EQModel(audio: audio))
        _analyzer = State(initialValue: SpectrumAnalyzer(engines: { audio.analyzerEngines }))
        // Start once the app has finished launching. The very first time, show the welcome
        // window first; audio (and the permission prompt) starts when it's closed.
        Task { @MainActor in
            if WelcomeController.needsWelcome {
                WelcomeController.shared.show { audio.start() }
            } else {
                audio.start()
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model, audio: audio, catalog: catalog, analyzer: analyzer)
        } label: {
            MenuBarIconLabel(analyzer: analyzer)
        }
        .menuBarExtraStyle(.window)

        Window("InHaus EQ", id: "eq") {
            EQWindowView(model: model, audio: audio, catalog: catalog, analyzer: analyzer)
        }
        .defaultSize(width: 760, height: 720)
        .windowResizability(.contentMinSize)
    }
}

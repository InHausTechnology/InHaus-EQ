//
//  Welcome.swift
//  InHausEQ
//
//  First-launch window: where the app lives, the permission prompt that's coming next,
//  and launch at login. Audio doesn't start (and macOS doesn't ask) until it's closed.
//

import SwiftUI
import AppKit

@MainActor
final class WelcomeController: NSObject, NSWindowDelegate {
    static let shared = WelcomeController()
    private static let shownKey = "InHausEQ.welcomeShown"

    static var needsWelcome: Bool {
        !UserDefaults.standard.bool(forKey: shownKey)
    }

    private var window: NSWindow?
    private var onFinish: (@MainActor () -> Void)?

    func show(onFinish: @escaping @MainActor () -> Void) {
        self.onFinish = onFinish
        let view = WelcomeView { [weak self] in self?.window?.close() }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Welcome to InHaus EQ"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Runs for "Get Started" and for the close button alike.
    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: Self.shownKey)
        let finish = onFinish
        onFinish = nil
        finish?()
    }
}

struct WelcomeView: View {
    let done: () -> Void
    @State private var launchAtLogin = true

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            VStack(spacing: 4) {
                Text("Welcome to InHaus EQ")
                    .font(.title2.weight(.semibold))
                Text("A system-wide equalizer for everything your Mac plays.")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 14) {
                WelcomeRow(symbol: "menubar.arrow.up.rectangle",
                           title: "It lives in your menu bar",
                           detail: "Click the InHaus EQ icon at the top of your screen for volume, per-app volume and headphones. The full equalizer is one click from there.")
                WelcomeRow(symbol: "waveform",
                           title: "macOS will ask to record system audio",
                           detail: "Click Allow. That's how the EQ reaches your audio. Nothing is recorded or saved.")
                WelcomeRow(symbol: "headphones",
                           title: "Every output keeps its own EQ",
                           detail: "Speakers, headphones and AirPods each remember their own settings.")
            }

            Toggle("Open InHaus EQ when I log in", isOn: $launchAtLogin)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                if launchAtLogin { LaunchAtLogin.set(true) }
                done()
            } label: {
                Text("Get Started")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(width: 440)
    }
}

private struct WelcomeRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.semibold)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

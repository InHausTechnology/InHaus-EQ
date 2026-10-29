//
//  AppVolumeList.swift
//  InHausEQ
//
//  Per-app volume sliders for the menu bar panel.
//

import SwiftUI
import AppKit
import Foundation

struct AppVolumeList: View {
    let manager: AppVolumeManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Apps")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if manager.apps.isEmpty {
                Text("Apps playing audio show up here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(manager.apps) { app in
                    AppVolumeRow(app: app, manager: manager)
                }
            }
        }
    }
}

private struct AppVolumeRow: View {
    let app: AppVolumeManager.AudioApp
    let manager: AppVolumeManager

    var body: some View {
        let percent = manager.percent(for: app.id)
        HStack(spacing: 8) {
            Group {
                if let icon = app.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app.dashed").resizable()
                }
            }
            .frame(width: 18, height: 18)
            .opacity(app.isPlaying ? 1 : 0.45)
            .help(app.isPlaying ? "Playing" : "Paused")

            Text(app.name)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 84, alignment: .leading)

            Slider(value: binding, in: 0...200)
                .controlSize(.small)

            Button("\(Int(percent.rounded()))%") { manager.setPercent(100, for: app.id) }
                .buttonStyle(.plain)
                .monospacedDigit()
                .font(.caption)
                .foregroundStyle(percent == 100 ? Color.secondary : (percent > 100 ? Color.orange : Color.primary))
                .frame(width: 40, alignment: .trailing)
                .help("Click to reset to 100%")
        }
        .font(.callout)
    }

    /// Snaps to 100% near the middle so "normal" is easy to land on.
    private var binding: Binding<Float> {
        Binding(
            get: { manager.percent(for: app.id) },
            set: { newValue in manager.setPercent(abs(newValue - 100) < 4 ? 100 : newValue, for: app.id) }
        )
    }
}

//
//  PermissionBanner.swift
//  InHausEQ
//
//  Shown when "System Audio Recording" is turned off for InHaus EQ.
//

import SwiftUI

struct PermissionBanner: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("InHaus EQ can't hear your Mac's audio", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
            Text("Turn on InHaus EQ in System Settings → Privacy & Security → Screen & System Audio Recording, under System Audio Recording Only. Until then your audio plays normally, without the EQ.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open System Settings") { AudioPermission.openSettings() }
                .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
    }
}

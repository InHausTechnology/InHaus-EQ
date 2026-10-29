//
//  LaunchAtLogin.swift
//  InHausEQ
//
//  Start-at-login (System Settings → General → Login Items) and the About panel.
//

import Foundation
import AppKit
import ServiceManagement

enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Turns it on or off. Returns an error message, or nil if it worked.
    @discardableResult
    static func set(_ on: Bool) -> String? {
        guard on != isEnabled else { return nil }
        do {
            if on {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return "Couldn't change Launch at Login: \(error.localizedDescription)"
        }
    }
}

enum AboutPanel {
    static func show() {
        let credits = """
        A system-wide equalizer for your Mac.

        Headphone corrections come from AutoEQ by Jaakko Pasanen (MIT License), \
        built from measurements by oratory1990, crinacle, Rtings and others credited \
        in the AutoEQ project.
        """
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let text = NSAttributedString(string: credits, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: style,
        ])
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: text])
    }
}

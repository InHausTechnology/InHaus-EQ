//
//  AudioPermission.swift
//  InHausEQ
//
//  The "System Audio Recording" permission that process taps need. macOS has no public
//  way to check it, so this uses the same private TCC calls other tap-based apps use
//  (AudioCap, FineTune). If those calls ever go away, status() returns .unknown and the
//  app simply starts as it did before.
//

import Foundation
import AppKit

enum AudioPermission {
    enum Status { case authorized, denied, unknown }

    static func status() -> Status {
        guard let preflight = preflightSPI else { return .unknown }
        switch preflight(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Shows the system prompt if it hasn't been answered yet. Calls back on the main thread.
    static func request(_ completion: @escaping @MainActor (Bool) -> Void) {
        guard let ask = requestSPI else {
            Task { @MainActor in completion(true) }   // can't ask: just try
            return
        }
        ask(service, nil) { granted in
            Task { @MainActor in completion(granted) }
        }
    }

    /// System Settings → Privacy & Security → Screen & System Audio Recording.
    static func openSettings() {
        let link = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
        if let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - TCC (private framework)

    private static let service = "kTCCServiceAudioCapture" as CFString

    private typealias PreflightFunc = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFunc = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

    private static let handle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    private static let preflightSPI: PreflightFunc? = {
        guard let handle = AudioPermission.handle, let symbol = dlsym(handle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(symbol, to: PreflightFunc.self)
    }()

    private static let requestSPI: RequestFunc? = {
        guard let handle = AudioPermission.handle, let symbol = dlsym(handle, "TCCAccessRequest") else { return nil }
        return unsafeBitCast(symbol, to: RequestFunc.self)
    }()
}

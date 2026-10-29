//
//  ProcessWatcher.swift
//  InHausEQ
//
//  Once a second, reads Core Audio's process list: which processes exist, which are
//  playing, and which are on a call (using the mic AND playing).
//

import Foundation
import CoreAudio

@MainActor
final class ProcessWatcher {
    /// Every tick: all audio process objects, and the ones playing right now.
    var onTick: ((_ all: Set<AudioObjectID>, _ playing: Set<AudioObjectID>) -> Void)?
    /// Only when something relevant changed: processes that just started playing,
    /// and every process currently on a voice or video call.
    var onChange: ((_ newlyPlaying: Set<AudioObjectID>, _ inCall: Set<AudioObjectID>) -> Void)?

    private(set) var all: Set<AudioObjectID> = []
    private(set) var playing: Set<AudioObjectID> = []
    private(set) var inCall: Set<AudioObjectID> = []

    private var loop: Task<Void, Never>?
    private var firstTick = true

    func start() {
        guard loop == nil else { return }
        all = []
        playing = []
        inCall = []
        firstTick = true
        tick()   // first reading right away, so callers can use `inCall` immediately
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { break }
                self?.tick()
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    private func tick() {
        let current = CA.processObjects()
        var nowPlaying = Set<AudioObjectID>()
        var nowInCall = Set<AudioObjectID>()
        for process in current where CA.isRunningOutput(process) {
            nowPlaying.insert(process)
            if CA.isRunningInput(process) { nowInCall.insert(process) }
        }

        let newlyPlaying = firstTick ? Set<AudioObjectID>() : nowPlaying.subtracting(playing)
        let callsChanged = nowInCall != inCall
        all = Set(current)
        playing = nowPlaying
        inCall = nowInCall
        firstTick = false

        onTick?(all, nowPlaying)
        if !newlyPlaying.isEmpty || callsChanged {
            onChange?(newlyPlaying, nowInCall)
        }
    }
}

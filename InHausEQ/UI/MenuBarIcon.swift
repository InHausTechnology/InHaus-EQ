//
//  MenuBarIcon.swift
//  InHausEQ
//
//  The menu bar icon: a tiny live spectrum (7 bars) while audio is playing, the
//  slider symbol otherwise. Drawn as a template image so it matches the menu bar's
//  light or dark appearance.
//

import SwiftUI
import AppKit

struct MenuBarIconLabel: View {
    let analyzer: SpectrumAnalyzer

    var body: some View {
        if analyzer.iconEnabled && analyzer.isLive {
            Image(nsImage: Self.bars(analyzer.iconLevels))
        } else {
            Image(systemName: "slider.vertical.3")
        }
    }

    /// 7 rounded bars, heights 0...1, bottom-aligned.
    static func bars(_ levels: [Float]) -> NSImage {
        let size = NSSize(width: 20, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            let count = max(levels.count, 1)
            let gap: CGFloat = 1.5
            let width = (rect.width - gap * CGFloat(count - 1)) / CGFloat(count)
            let minHeight: CGFloat = 2
            NSColor.black.setFill()
            for (i, level) in levels.enumerated() {
                let height = minHeight + CGFloat(min(max(level, 0), 1)) * (rect.height - 2 - minHeight)
                let bar = NSRect(x: CGFloat(i) * (width + gap), y: 1, width: width, height: height)
                NSBezierPath(roundedRect: bar, xRadius: width / 2, yRadius: width / 2).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

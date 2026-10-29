//
//  ResponseCurveView.swift
//  InHausEQ
//
//  Draws what the EQ is doing (the curve, from the same filter math as the audio engine)
//  and, when given an analyzer, the live spectrum of what's playing behind it.
//

import SwiftUI
import Foundation

struct ResponseCurveView: View {
    let bands: [EQBand]
    let preampDB: Float
    var sampleRate: Double = 48000
    var height: CGFloat = 160
    var showsLabels = true
    /// Live spectrum. When set, the view redraws whenever the analyzer publishes new levels.
    var analyzer: SpectrumAnalyzer? = nil

    private static let minHz = 20.0
    private static let maxHz = 20000.0
    private static let rangeDB = 15.0
    private static let gridHz: [Double] = [50, 100, 200, 500, 1000, 2000, 5000, 10000]
    private static let gridDB: [Double] = [-12, -6, 6, 12]
    private static let points = 256

    // Spectrum scale (its own, independent of the EQ's ±15 dB). The analyzer's tilt
    // around 1 kHz makes typical music look roughly level, like most analyzers.
    private static let spectrumFloor: Float = -84
    private static let spectrumTop: Float = -6

    var body: some View {
        // Read the analyzer here (not inside the Canvas) so each new frame of levels
        // re-renders this view.
        let spectrum: (after: [Float], before: [Float])? =
            (analyzer?.isLive ?? false) ? (analyzer?.after ?? [], analyzer?.before ?? []) : nil
        let frame = analyzer?.frame ?? 0

        Canvas { context, size in
            _ = frame
            if let spectrum {
                drawSpectrum(after: spectrum.after, before: spectrum.before, in: &context, size: size)
            }
            drawCurve(in: &context, size: size)
        }
        .frame(height: height)
        .onAppear { analyzer?.addViewer() }
        .onDisappear { analyzer?.removeViewer() }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.07)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement()
        .accessibilityLabel(analyzer == nil ? "EQ response curve" : "EQ response curve and live spectrum")
    }

    // MARK: - Geometry

    private static func x(_ hz: Double, width: CGFloat) -> CGFloat {
        CGFloat(log10(hz / minHz) / log10(maxHz / minHz)) * width
    }

    // MARK: - Spectrum

    private func drawSpectrum(after: [Float], before: [Float],
                              in context: inout GraphicsContext, size: CGSize) {
        let w = size.width
        let h = size.height
        let count = min(SpectrumAnalyzer.points, after.count, before.count)
        guard count > 1 else { return }

        func y(_ db: Float, index i: Int) -> CGFloat {
            let t = (SpectrumAnalyzer.tilted(db, index: i) - Self.spectrumFloor)
                / (Self.spectrumTop - Self.spectrumFloor)
            return h - CGFloat(min(max(t, 0), 1)) * h
        }
        func line(_ levels: [Float]) -> Path {
            var path = Path()
            for i in 0..<count {
                let point = CGPoint(x: Self.x(SpectrumAnalyzer.frequency(atIndex: i), width: w),
                                    y: y(levels[i], index: i))
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            return path
        }

        // After the EQ: filled, so you see what you're hearing.
        let afterLine = line(after)
        var area = afterLine
        area.addLine(to: CGPoint(x: w, y: h))
        area.addLine(to: CGPoint(x: 0, y: h))
        area.closeSubpath()
        context.fill(area, with: .linearGradient(
            Gradient(colors: [Color.primary.opacity(0.22), Color.primary.opacity(0.04)]),
            startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: h)))
        context.stroke(afterLine, with: .color(Color.primary.opacity(0.35)), lineWidth: 1)

        // Before the EQ: a faint dashed line, so the EQ's effect is the gap between them.
        context.stroke(line(before), with: .color(Color.secondary.opacity(0.45)),
                       style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

        if showsLabels {
            let legend = Text("Spectrum: filled = after EQ · dashed = before")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            context.draw(legend, at: CGPoint(x: w - 6, y: 4), anchor: .topTrailing)
        }
    }

    // MARK: - EQ curve

    private func drawCurve(in context: inout GraphicsContext, size: CGSize) {
        let w = size.width
        let h = size.height
        let inset: CGFloat = showsLabels ? 14 : 6
        let xFor: (Double) -> CGFloat = { hz in Self.x(hz, width: w) }
        let yFor: (Double) -> CGFloat = { db in
            let clamped = min(max(db, -Self.rangeDB), Self.rangeDB)
            return h / 2 - CGFloat(clamped / Self.rangeDB) * (h / 2 - inset)
        }

        // Grid
        var grid = Path()
        for hz in Self.gridHz {
            grid.move(to: CGPoint(x: xFor(hz), y: 0))
            grid.addLine(to: CGPoint(x: xFor(hz), y: h))
        }
        for db in Self.gridDB {
            grid.move(to: CGPoint(x: 0, y: yFor(db)))
            grid.addLine(to: CGPoint(x: w, y: yFor(db)))
        }
        context.stroke(grid, with: .color(Color.secondary.opacity(0.18)), lineWidth: 0.5)

        var zeroLine = Path()
        zeroLine.move(to: CGPoint(x: 0, y: yFor(0)))
        zeroLine.addLine(to: CGPoint(x: w, y: yFor(0)))
        context.stroke(zeroLine, with: .color(Color.secondary.opacity(0.45)), lineWidth: 1)

        if showsLabels {
            for hz in Self.gridHz {
                let label = hz >= 1000 ? "\(Int(hz / 1000))k" : "\(Int(hz))"
                context.draw(Text(label).font(.system(size: 9)).foregroundStyle(.secondary),
                             at: CGPoint(x: xFor(hz) + 3, y: h - 3), anchor: .bottomLeading)
            }
            for db in Self.gridDB {
                let label = db > 0 ? "+\(Int(db))" : "\(Int(db))"
                context.draw(Text(label).font(.system(size: 9)).foregroundStyle(.secondary),
                             at: CGPoint(x: 4, y: yFor(db) - 2), anchor: .bottomLeading)
            }
        }

        // Curve
        var curve = Path()
        let rate = sampleRate > 0 ? sampleRate : 48000
        bands.withUnsafeBufferPointer { buffer in
            let count = Int32(buffer.count)
            for i in 0..<Self.points {
                let t = Double(i) / Double(Self.points - 1)
                let hz = Self.minHz * pow(Self.maxHz / Self.minHz, t)
                let db = eq_response_db(buffer.baseAddress, count, preampDB, rate, hz)
                let point = CGPoint(x: CGFloat(t) * w, y: yFor(db))
                if i == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
            }
        }

        var area = curve
        area.addLine(to: CGPoint(x: w, y: yFor(0)))
        area.addLine(to: CGPoint(x: 0, y: yFor(0)))
        area.closeSubpath()
        context.fill(area, with: .color(Color.accentColor.opacity(0.15)))
        context.stroke(curve, with: .color(Color.accentColor),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
    }
}

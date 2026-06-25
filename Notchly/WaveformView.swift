//
//  WaveformView.swift
//  Notchly — Phase 2: Waveform visualizer
//
//  5 white vertical bars, 3pt wide, 4pt gap, rounded caps. Height range
//  4pt (idle / silence) → 28pt (loud). Driven by AudioLevelProvider.levels.
//  When audio is silent the bands decay to ~0 and the bars settle flat at 4pt.
//

import SwiftUI

struct WaveformView: View {
    /// 5 values, 0...1.
    var levels: [CGFloat]
    /// Tallest a bar can get. 28pt for the expanded panel; pass ~22pt so the
    /// bars sit comfortably inside the 36pt collapsed notch.
    var maxBarHeight: CGFloat = 28

    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 4
    private let minBarHeight: CGFloat = 4
    private let barCount = 5

    var body: some View {
        HStack(alignment: .center, spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { i in
                Capsule(style: .continuous)
                    .fill(Color.white)
                    .frame(width: barWidth, height: height(for: i))
            }
        }
        .frame(height: maxBarHeight, alignment: .center)
        .animation(.easeOut(duration: 0.10), value: levels)
    }

    private func height(for index: Int) -> CGFloat {
        let level = index < levels.count ? min(1, max(0, levels[index])) : 0
        return minBarHeight + (maxBarHeight - minBarHeight) * level
    }
}

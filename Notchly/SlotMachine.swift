//
//  SlotMachine.swift
//  Notchly — bonus slot machine
//
//  A free 3-reel bonus spin offered after you win a round of poker or blackjack.
//  Reels physically roll (scroll vertically) and decelerate onto the result,
//  staggered left-to-right. One spin per win; payout is added to that game.
//

import SwiftUI
import AppKit
import Combine

struct SlotSymbol {
    let icon: String
    let color: Color
    let triple: Int      // payout for three of a kind
}

enum Slot {
    static let symbols: [SlotSymbol] = [
        SlotSymbol(icon: "star.fill",       color: .yellow,  triple: 100),
        SlotSymbol(icon: "bell.fill",       color: .orange,  triple: 150),
        SlotSymbol(icon: "suit.heart.fill", color: .red,     triple: 200),
        SlotSymbol(icon: "crown.fill",      color: Color(red: 0.95, green: 0.8, blue: 0.3), triple: 300),
        SlotSymbol(icon: "diamond.fill",    color: .cyan,    triple: 500)   // jackpot
    ]
    static let pairPayout = 40
    static let symbolHeight: CGFloat = 96
}

@MainActor
final class SlotEngine: ObservableObject {
    @Published private(set) var results = [0, 1, 2]
    @Published private(set) var spinID = 0
    @Published private(set) var spinning = false
    @Published private(set) var done = false
    @Published private(set) var reward = 0
    @Published private(set) var message = "Free bonus spin!"

    private let onReward: (Int) -> Void
    init(onReward: @escaping (Int) -> Void) { self.onReward = onReward }

    func spin() async {
        guard !spinning, !done else { return }
        let n = Slot.symbols.count
        results = (0..<3).map { _ in Int.random(in: 0..<n) }
        spinID += 1                                 // triggers the reels to roll
        spinning = true
        message = "Rolling…"
        NSSound(named: "Pop")?.play()

        // Let the reels roll + settle (see SlotReel stagger).
        try? await Task.sleep(nanoseconds: 2_300_000_000)

        reward = payout(results)
        spinning = false
        done = true
        if reward > 0 {
            onReward(reward)
            message = "Bonus won: +\(reward) chips!"
            NSSound(named: "Glass")?.play()
        } else {
            message = "No match — better luck next win"
            NSSound(named: "Basso")?.play()
        }
    }

    private func payout(_ r: [Int]) -> Int {
        if r[0] == r[1] && r[1] == r[2] { return Slot.symbols[r[0]].triple }
        if r[0] == r[1] || r[1] == r[2] || r[0] == r[2] { return Slot.pairPayout }
        return 0
    }
}

// MARK: - A single rolling reel

struct SlotReel: View {
    let result: Int
    let spinID: Int
    let index: Int                 // 0,1,2 for stagger
    private let cycles = 8
    private let h = Slot.symbolHeight

    @State private var offset: CGFloat = 0

    /// Long strip: several full cycles then the result at the end.
    private var strip: [Int] {
        var s: [Int] = []
        for _ in 0..<cycles { s += Array(0..<Slot.symbols.count) }
        s.append(result)
        return s
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(strip.enumerated()), id: \.offset) { _, sym in
                symbolCell(Slot.symbols[sym])
            }
        }
        .offset(y: offset)
        .frame(width: 78, height: h, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.25), lineWidth: 1.5))
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.06)))
        .onChange(of: spinID) { _, _ in roll() }
    }

    private func roll() {
        offset = 0                                              // back to the top
        let target = -CGFloat(strip.count - 1) * h             // land on the result
        let duration = 1.4 + Double(index) * 0.35              // staggered stops
        withAnimation(.timingCurve(0.15, 0.85, 0.2, 1.0, duration: duration)) {
            offset = target
        }
    }

    private func symbolCell(_ s: SlotSymbol) -> some View {
        Image(systemName: s.icon)
            .font(.system(size: 40, weight: .bold))
            .foregroundStyle(s.color)
            .frame(width: 78, height: h)
    }
}

// MARK: - The machine

struct SlotMachineView: View {
    let onReward: (Int) -> Void
    let onClose: () -> Void
    @StateObject private var engine: SlotEngine

    init(onReward: @escaping (Int) -> Void, onClose: @escaping () -> Void) {
        self.onReward = onReward
        self.onClose = onClose
        _engine = StateObject(wrappedValue: SlotEngine(onReward: onReward))
    }

    var body: some View {
        VStack(spacing: 18) {
            Text("🎰 BONUS SPIN")
                .font(.system(.title2, design: .rounded).weight(.black))
                .foregroundStyle(.yellow)

            HStack(spacing: 12) {
                ForEach(0..<3, id: \.self) { i in
                    SlotReel(result: engine.results[i], spinID: engine.spinID, index: i)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 16).fill(.black.opacity(0.35)))
            .overlay(
                // Payline through the centre.
                Rectangle().fill(.yellow.opacity(0.35)).frame(height: 2)
            )

            Text(engine.message)
                .font(.system(.headline, design: .rounded).weight(.bold))
                .foregroundStyle(engine.reward > 0 ? .green : .white)
                .frame(height: 24)

            if engine.done {
                gameButton("Collect", tint: .green, action: onClose)
            } else {
                gameButton(engine.spinning ? "Rolling…" : "SPIN", tint: .yellow) {
                    Task { await engine.spin() }
                }
                .disabled(engine.spinning)
            }
        }
        .padding(28)
        .frame(width: 360, height: 320)
        .background(
            LinearGradient(colors: [Color(red: 0.12, green: 0.05, blue: 0.2),
                                    Color(red: 0.04, green: 0.02, blue: 0.08)],
                           startPoint: .top, endPoint: .bottom))
    }

    private func gameButton(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(.title3, design: .rounded).weight(.black))
                .foregroundStyle(.black)
                .frame(width: 180)
                .padding(.vertical, 10)
                .background(Capsule().fill(tint))
        }
        .buttonStyle(.plain)
    }
}

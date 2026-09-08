//
//  RouletteGame.swift
//  Notchly — European Roulette (single zero)
//
//  Place bets on numbers / red-black / even-odd / high-low / dozens, spin the
//  wheel, get paid. Bankroll + high score persist.
//

import Foundation
import Combine
import AppKit

enum RouletteBet: Hashable {
    case straight(Int)            // 35:1
    case red, black, even, odd, low, high   // 1:1
    case dozen(Int)               // 2:1  (1,2,3)
}

@MainActor
final class RouletteGame: ObservableObject {

    enum Phase { case betting, spinning, result }

    /// Clockwise European wheel order.
    static let wheelOrder = [0, 32, 15, 19, 4, 21, 2, 25, 17, 34, 6, 27, 13, 36, 11,
                             30, 8, 23, 10, 5, 24, 16, 33, 1, 20, 14, 31, 9, 22, 18,
                             29, 7, 28, 12, 35, 3, 26]
    static let redNumbers: Set<Int> = [1, 3, 5, 7, 9, 12, 14, 16, 18, 19, 21, 23, 25,
                                       27, 30, 32, 34, 36]

    @Published private(set) var phase: Phase = .betting
    @Published private(set) var result: Int? = nil
    @Published private(set) var bets: [RouletteBet: Int] = [:]
    @Published private(set) var chips: Int { didSet { defaults.set(chips, forKey: K.chips); if chips > highScore { highScore = chips } } }
    @Published private(set) var highScore: Int { didSet { defaults.set(highScore, forKey: K.high) } }
    @Published var chipSize: Int = 25
    @Published private(set) var message = "Place your bets"
    @Published private(set) var lastNet = 0

    private let defaults = UserDefaults.standard
    private enum K { static let chips = "notchly.roulette.chips", high = "notchly.roulette.high" }

    init() {
        let saved = defaults.object(forKey: K.chips) as? Int
        let start = (saved == nil || saved! <= 0) ? 500 : saved!
        chips = start
        highScore = max(defaults.integer(forKey: K.high), start)
    }

    var totalBet: Int { bets.values.reduce(0, +) }

    static func color(_ n: Int) -> NumberColor {
        if n == 0 { return .green }
        return redNumbers.contains(n) ? .red : .black
    }
    enum NumberColor { case green, red, black }

    // MARK: - Betting

    func setChipSize(_ v: Int) { chipSize = v }

    func place(_ bet: RouletteBet) {
        guard phase != .spinning, chips >= chipSize else { return }
        chips -= chipSize
        bets[bet, default: 0] += chipSize
        if phase == .result { phase = .betting; result = nil }
    }

    func clearBets() {
        guard phase != .spinning else { return }
        chips += totalBet
        bets = [:]
    }

    // MARK: - Spin

    func spin() async {
        guard phase != .spinning, totalBet > 0 else { return }
        let wager = totalBet
        phase = .spinning
        result = Int.random(in: 0...36)
        message = "Spinning…"
        play("Pop")

        try? await Task.sleep(nanoseconds: 3_600_000_000)   // matches the wheel animation

        guard let r = result else { return }
        var won = 0
        for (bet, amount) in bets where wins(bet, r) {
            won += amount * (payout(bet) + 1)
        }
        chips += won
        lastNet = won - wager
        bets = [:]
        phase = .result

        let c = Self.color(r)
        let colorName = c == .green ? "green" : (c == .red ? "red" : "black")
        if lastNet > 0 { message = "\(r) \(colorName) — won \(lastNet)!"; play("Glass") }
        else { message = "\(r) \(colorName) — lost \(wager)"; play("Basso") }

        if chips <= 0 { chips = 500; message = "Out of chips — reloaded to 500" }
    }

    private func payout(_ bet: RouletteBet) -> Int {
        switch bet {
        case .straight: return 35
        case .dozen: return 2
        default: return 1
        }
    }

    private func wins(_ bet: RouletteBet, _ r: Int) -> Bool {
        switch bet {
        case .straight(let n): return r == n
        case .red: return Self.redNumbers.contains(r)
        case .black: return r != 0 && !Self.redNumbers.contains(r)
        case .even: return r != 0 && r % 2 == 0
        case .odd: return r % 2 == 1
        case .low: return (1...18).contains(r)
        case .high: return (19...36).contains(r)
        case .dozen(let d): return ((d - 1) * 12 + 1...d * 12).contains(r)
        }
    }

    private func play(_ name: String) { NSSound(named: name)?.play() }
}

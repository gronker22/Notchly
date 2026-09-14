//
//  CasinoProgress.swift
//  Notchly — shared casino progression
//
//  Cross-game (poker + blackjack) daily bonus, day-streak, and an all-time
//  chip high score. Persisted in UserDefaults. The daily bonus can be claimed
//  once per calendar day across both games; the streak grows on consecutive
//  days and resets after a gap.
//

import Foundation
import Combine

@MainActor
final class CasinoProgress: ObservableObject {
    static let shared = CasinoProgress()

    @Published private(set) var streak = 0
    @Published private(set) var bestChips = 0

    private let defaults = UserDefaults.standard
    private enum K {
        static let streak = "notchly.casino.streak"
        static let lastClaimDay = "notchly.casino.lastClaimDay"   // days since epoch
        static let best = "notchly.casino.bestChips"
    }

    private init() {
        streak = defaults.integer(forKey: K.streak)
        bestChips = defaults.integer(forKey: K.best)
    }

    private var today: Int { Int(Date().timeIntervalSince1970 / 86_400) }

    /// Award once per calendar day. Returns the bonus amount and the new streak,
    /// or nil if the bonus was already claimed today.
    func claimDailyBonus() -> (amount: Int, streak: Int)? {
        let last = defaults.object(forKey: K.lastClaimDay) as? Int
        guard last != today else { return nil }

        if let last, today - last == 1 { streak += 1 } else { streak = 1 }
        defaults.set(streak, forKey: K.streak)
        defaults.set(today, forKey: K.lastClaimDay)

        let amount = min(500, 100 + (streak - 1) * 50)   // 100, 150, 200 … capped at 500
        return (amount, streak)
    }

    /// Record a chip balance; keeps the all-time high.
    func recordChips(_ chips: Int) {
        guard chips > bestChips else { return }
        bestChips = chips
        defaults.set(bestChips, forKey: K.best)
    }
}

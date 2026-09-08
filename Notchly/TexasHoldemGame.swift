//
//  TexasHoldemGame.swift
//  Notchly — Texas Hold'em (No-Limit) vs. 2 AI opponents
//
//  Full hand: blinds, hole cards, flop/turn/river, fold/check/call/raise/all-in,
//  side pots, showdown with 7-card best-5 evaluation. Easy/Hard AI with basic
//  bluffing. Bankroll + session stats persist. System-sound effects (toggle).
//

import Foundation
import Combine
import AppKit
import SwiftUI

@MainActor
final class TexasHoldemGame: ObservableObject {

    enum Stage { case idle, preflop, flop, turn, river, showdown, handOver }
    enum Difficulty: String { case easy, hard }
    private enum Decision { case fold, check, call, allIn, raiseTo(Int) }

    struct Player: Identifiable {
        let id: Int
        let name: String
        let isAI: Bool
        var chips: Int
        var avatar: String = "person.fill"
        var trait: String = ""
        var hole: [Card] = []
        var bet: Int = 0          // contributed this round
        var committed: Int = 0    // contributed this hand
        var folded = false
        var allIn = false
        var acted = false
        var lastAction = ""
    }

    @Published private(set) var players: [Player]
    @Published private(set) var community: [Card] = []
    @Published private(set) var stage: Stage = .idle
    @Published private(set) var pot: Int = 0
    @Published private(set) var currentBetToCall: Int = 0
    @Published private(set) var current: Int = 0
    @Published private(set) var dealerButton = 0
    @Published private(set) var message = "Tap Deal to start"
    @Published private(set) var revealAll = false
    @Published private(set) var resultText = ""

    @Published var difficulty: Difficulty { didSet { defaults.set(difficulty.rawValue, forKey: K.diff) } }
    @Published var soundOn: Bool { didSet { defaults.set(soundOn, forKey: K.sound) } }

    // Session stats
    @Published private(set) var wins = 0
    @Published private(set) var losses = 0
    @Published private(set) var biggestPot = 0
    @Published private(set) var winStreak = 0

    // Live overlay + highlights
    @Published private(set) var winProbability: Double = 0   // your equity, 0...1
    @Published private(set) var winnerSeats: Set<Int> = []

    let smallBlind = 10, bigBlind = 20, startingStack = 1000
    private var minRaise = 20
    private var deck: [Card] = []
    private let dealAnim = Animation.spring(response: 0.45, dampingFraction: 0.8)

    private let defaults = UserDefaults.standard
    private enum K {
        static let chips = "notchly.holdem.chips", diff = "notchly.holdem.diff"
        static let sound = "notchly.holdem.sound", wins = "notchly.holdem.wins"
        static let losses = "notchly.holdem.losses", bigPot = "notchly.holdem.bigpot"
    }

    init() {
        let saved = defaults.object(forKey: K.chips) as? Int
        let bank = (saved == nil || saved! < 20) ? 1000 : saved!
        players = [
            Player(id: 0, name: "You", isAI: false, chips: bank, avatar: "person.crop.circle.fill"),
            Player(id: 1, name: "Ava", isAI: true, chips: 1000, avatar: "brain.head.profile", trait: "Calculating"),
            Player(id: 2, name: "Rex", isAI: true, chips: 1000, avatar: "flame.fill", trait: "Aggressive"),
            Player(id: 3, name: "Mia", isAI: true, chips: 1000, avatar: "sparkles", trait: "Tricky"),
            Player(id: 4, name: "Leo", isAI: true, chips: 1000, avatar: "tortoise.fill", trait: "Patient")
        ]
        difficulty = Difficulty(rawValue: defaults.string(forKey: K.diff) ?? "easy") ?? .easy
        soundOn = defaults.object(forKey: K.sound) as? Bool ?? true
        wins = defaults.integer(forKey: K.wins)
        losses = defaults.integer(forKey: K.losses)
        biggestPot = defaults.integer(forKey: K.bigPot)
    }

    var you: Player { players[0] }
    var toCallForYou: Int { max(0, currentBetToCall - players[0].bet) }
    var canCheck: Bool { toCallForYou == 0 }
    var isYourTurn: Bool { current == 0 && (stage == .preflop || stage == .flop || stage == .turn || stage == .river) && !players[0].folded && !players[0].allIn }
    var minRaiseTo: Int { min(players[0].bet + players[0].chips, currentBetToCall + minRaise) }
    var maxRaiseTo: Int { players[0].bet + players[0].chips }
    var potOddsForYou: Double { toCallForYou > 0 ? Double(toCallForYou) / Double(pot + toCallForYou) : 0 }
    var isBetting: Bool { stage == .preflop || stage == .flop || stage == .turn || stage == .river }
    var smallBlindSeat: Int { (dealerButton + 1) % players.count }
    var bigBlindSeat: Int { (dealerButton + 2) % players.count }

    // MARK: - Equity (Monte-Carlo win probability for your hand)

    func computeEquity() {
        guard !players[0].folded, players[0].hole.count == 2 else { winProbability = 0; return }
        let opponents = players.indices.filter { $0 != 0 && !players[$0].folded }.count
        guard opponents > 0 else { winProbability = 1; return }

        let known = Set((players[0].hole + community).map { $0.rank * 10 + suitIndex($0.suit) })
        var remaining: [Card] = []
        for s in Card.Suit.allCases {
            for r in 2...14 where !known.contains(r * 10 + suitIndex(s)) {
                remaining.append(Card(rank: r, suit: s))
            }
        }

        let trials = 320
        let needBoard = 5 - community.count
        var winSum = 0.0
        for _ in 0..<trials {
            var pool = remaining; pool.shuffle()
            var idx = 0
            var oppHands: [[Card]] = []
            for _ in 0..<opponents { oppHands.append([pool[idx], pool[idx + 1]]); idx += 2 }
            var board = community
            for _ in 0..<needBoard { board.append(pool[idx]); idx += 1 }
            let mine = HandEval.best7(players[0].hole + board)
            var better = 0, equal = 0
            for oh in oppHands {
                let c = HandEval.compare(HandEval.best7(oh + board), mine)
                if c > 0 { better += 1 } else if c == 0 { equal += 1 }
            }
            if better == 0 { winSum += equal == 0 ? 1.0 : 1.0 / Double(equal + 1) }
        }
        winProbability = winSum / Double(trials)
    }

    private func suitIndex(_ s: Card.Suit) -> Int {
        Card.Suit.allCases.firstIndex(of: s) ?? 0
    }

    // MARK: - Deck

    private func buildDeck() {
        deck = Card.Suit.allCases.flatMap { s in (2...14).map { Card(rank: $0, suit: s) } }
        deck.shuffle()
    }
    private func draw() -> Card { deck.removeLast() }

    // MARK: - Hand lifecycle

    func startHand() async {
        guard players[0].chips >= bigBlind else {
            message = "Out of chips"; resultText = "Tap New Game"; stage = .handOver; return
        }
        for i in players.indices where players[i].isAI && players[i].chips < bigBlind {
            players[i].chips = startingStack         // AI rebuy so the table stays full
        }
        buildDeck()
        for i in players.indices {
            players[i].hole = []; players[i].bet = 0; players[i].committed = 0
            players[i].folded = false; players[i].allIn = false; players[i].acted = false
            players[i].lastAction = ""
        }
        community = []; pot = 0; revealAll = false; resultText = ""
        winnerSeats = []; winProbability = 0
        dealerButton = (dealerButton + 1) % players.count
        stage = .preflop
        message = "Dealing…"

        // Deal hole cards one at a time around the table (animated).
        for _ in 0..<2 {
            for i in players.indices {
                withAnimation(dealAnim) { players[i].hole.append(draw()) }
                play("Pop")
                try? await Task.sleep(nanoseconds: 130_000_000)
            }
        }

        let sb = (dealerButton + 1) % players.count
        let bb = (dealerButton + 2) % players.count
        postBlind(sb, smallBlind); postBlind(bb, bigBlind)
        currentBetToCall = bigBlind; minRaise = bigBlind
        stage = .preflop
        current = (bb + 1) % players.count
        message = "Pre-flop"
        play("Pop")
        await processTurns()
    }

    private func postBlind(_ i: Int, _ amount: Int) {
        let actual = min(amount, players[i].chips)
        contribute(i, actual)
        if players[i].chips == 0 { players[i].allIn = true }
    }

    private func contribute(_ i: Int, _ amount: Int) {
        players[i].chips -= amount
        players[i].bet += amount
        players[i].committed += amount
        pot += amount
    }

    // MARK: - Turn engine

    private func needsToAct(_ i: Int) -> Bool {
        !players[i].folded && !players[i].allIn && (players[i].bet < currentBetToCall || !players[i].acted)
    }

    private func nextActor(after i: Int) -> Int? {
        for step in 1...players.count {
            let j = (i + step) % players.count
            if needsToAct(j) { return j }
        }
        return nil
    }

    private func processTurns() async {
        while true {
            let active = players.indices.filter { !players[$0].folded }
            if active.count == 1 { await awardWalk(active[0]); return }

            if let next = needsToAct(current) ? current : nextActor(after: current) {
                current = next
                if players[current].isAI {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    apply(aiDecide(current), by: current)
                    continue
                } else {
                    computeEquity()                 // refresh live win % for the HUD
                    message = "Your turn"
                    return                          // wait for UI
                }
            } else {
                // betting round complete
                await advanceStreet()
                if stage == .showdown { await showdown(); return }
                if stage == .handOver { return }
            }
        }
    }

    // MARK: - Apply actions

    private func apply(_ d: Decision, by i: Int) {
        switch d {
        case .fold:
            withAnimation(.easeInOut(duration: 0.3)) { players[i].folded = true }
            players[i].acted = true
            players[i].lastAction = "Fold"; play("Bottle")
        case .check:
            players[i].acted = true; players[i].lastAction = "Check"; play("Morse")
        case .call:
            let amt = min(currentBetToCall - players[i].bet, players[i].chips)
            contribute(i, amt)
            if players[i].chips == 0 { players[i].allIn = true }
            players[i].acted = true; players[i].lastAction = "Call \(amt)"; play("Tink")
        case .allIn:
            let amt = players[i].chips
            contribute(i, amt); players[i].allIn = true; players[i].acted = true
            if players[i].bet > currentBetToCall {
                minRaise = max(minRaise, players[i].bet - currentBetToCall)
                currentBetToCall = players[i].bet
                for j in players.indices where j != i && !players[j].folded && !players[j].allIn { players[j].acted = false }
            }
            players[i].lastAction = "All-in \(amt)"; play("Tink")
        case .raiseTo(let target):
            let capped = min(target, players[i].bet + players[i].chips)
            let added = capped - players[i].bet
            contribute(i, added)
            minRaise = max(minRaise, capped - currentBetToCall)
            currentBetToCall = capped
            if players[i].chips == 0 { players[i].allIn = true }
            for j in players.indices where j != i && !players[j].folded && !players[j].allIn { players[j].acted = false }
            players[i].acted = true; players[i].lastAction = "Raise \(capped)"; play("Tink")
        }
    }

    // MARK: - Human actions (called from UI)

    func youFold() { guard isYourTurn else { return }; apply(.fold, by: 0); resume() }
    func youCheckCall() { guard isYourTurn else { return }; apply(canCheck ? .check : .call, by: 0); resume() }
    func youRaise(to amount: Int) { guard isYourTurn else { return }; apply(.raiseTo(amount), by: 0); resume() }
    func youAllIn() { guard isYourTurn else { return }; apply(.allIn, by: 0); resume() }
    private func resume() { Task { await processTurns() } }

    // MARK: - Streets

    private func advanceStreet() async {
        for i in players.indices { players[i].bet = 0; players[i].acted = false }
        currentBetToCall = 0; minRaise = bigBlind

        switch stage {
        case .preflop:
            stage = .flop; message = "Flop"
            for _ in 0..<3 {
                withAnimation(dealAnim) { community.append(draw()) }
                play("Pop")
                try? await Task.sleep(nanoseconds: 180_000_000)
            }
        case .flop:
            stage = .turn; message = "Turn"
            withAnimation(dealAnim) { community.append(draw()) }
            play("Pop")
        case .turn:
            stage = .river; message = "River"
            withAnimation(dealAnim) { community.append(draw()) }
            play("Pop")
        case .river:
            stage = .showdown
        default: break
        }
        current = firstActor()
        try? await Task.sleep(nanoseconds: 400_000_000)
    }

    private func firstActor() -> Int {
        for step in 1...players.count {
            let j = (dealerButton + step) % players.count
            if needsToAct(j) { return j }
        }
        return (dealerButton + 1) % players.count
    }

    // MARK: - Showdown / awarding

    private func awardWalk(_ winner: Int) async {
        let total = players.map { $0.committed }.reduce(0, +)
        players[winner].chips += total
        finishHand(potTotal: total, winners: [winner], reason: "\(players[winner].name) wins (all folded)")
    }

    private func showdown() async {
        revealAll = true
        play("Glass")
        try? await Task.sleep(nanoseconds: 400_000_000)

        let total = players.map { $0.committed }.reduce(0, +)
        var contribs = players.map { $0.committed }
        var awards = [Int](repeating: 0, count: players.count)
        var allWinners = Set<Int>()

        while contribs.contains(where: { $0 > 0 }) {
            let minC = contribs.filter { $0 > 0 }.min()!
            var potAmount = 0
            var contenders: [Int] = []
            for i in players.indices where contribs[i] > 0 {
                potAmount += minC
                contribs[i] -= minC
                if !players[i].folded { contenders.append(i) }
            }
            guard !contenders.isEmpty else { continue }
            let scored = contenders.map { ($0, HandEval.best7(players[$0].hole + community)) }
            let best = scored.map { $0.1 }.max { HandEval.compare($0, $1) < 0 }!
            let winners = scored.filter { HandEval.compare($0.1, best) == 0 }.map { $0.0 }
            let share = potAmount / winners.count
            let rem = potAmount % winners.count
            for (k, w) in winners.enumerated() {
                awards[w] += share + (k < rem ? 1 : 0)
                allWinners.insert(w)
            }
        }
        for i in players.indices { players[i].chips += awards[i] }

        let names = allWinners.sorted().map { players[$0].name }.joined(separator: " & ")
        let handName = HandEval.name(HandEval.best7(players[allWinners.first ?? 0].hole + community))
        finishHand(potTotal: total, winners: Array(allWinners), reason: "\(names) win \(total) — \(handName)")
    }

    private func finishHand(potTotal: Int, winners: [Int], reason: String) {
        stage = .handOver
        message = "Hand complete"
        resultText = reason
        biggestPot = max(biggestPot, potTotal)
        withAnimation(.easeInOut(duration: 0.3)) { winnerSeats = Set(winners) }
        if winners.contains(0) { wins += 1; winStreak += 1 } else { losses += 1; winStreak = 0 }
        persist()
    }

    private func persist() {
        defaults.set(players[0].chips, forKey: K.chips)
        defaults.set(wins, forKey: K.wins)
        defaults.set(losses, forKey: K.losses)
        defaults.set(biggestPot, forKey: K.bigPot)
    }

    func newGame() {
        players[0].chips = 1000
        persist()
        stage = .idle; message = "Tap Deal to start"; resultText = ""
        community = []; pot = 0
    }

    func resetStats() {
        wins = 0; losses = 0; biggestPot = 0; persist()
    }

    // MARK: - AI

    private func aiDecide(_ i: Int) -> Decision {
        let toCall = currentBetToCall - players[i].bet
        let strength = handStrength(i)
        let hard = difficulty == .hard
        let bluff = hard && Double.random(in: 0..<1) < 0.16
        let potOdds = toCall > 0 ? Double(toCall) / Double(pot + toCall) : 0

        func raise() -> Decision {
            let size = max(minRaise, Int(Double(pot) * (hard ? 0.7 : 0.5)))
            let target = currentBetToCall + size
            if target >= players[i].bet + players[i].chips { return .allIn }
            return .raiseTo(target)
        }

        // Pre-flop with no raise yet: limp in to see the flop instead of
        // folding off the bat. Only premium hands raise; nobody folds.
        if community.isEmpty && currentBetToCall <= bigBlind {
            if toCall == 0 { return .check }
            if strength > 0.85 { return raise() }
            return .call
        }

        if toCall == 0 {
            if strength > (hard ? 0.55 : 0.72) || bluff { return raise() }
            return .check
        } else {
            if players[i].chips <= toCall {
                return (strength > 0.5 || bluff) ? .allIn : .fold
            }
            if strength > (hard ? 0.7 : 0.82) || bluff { return raise() }
            let callThreshold = hard ? 0.32 : 0.42
            if strength > callThreshold && strength >= potOdds * 0.8 { return .call }
            return .fold
        }
    }

    private func handStrength(_ i: Int) -> Double {
        let hole = players[i].hole
        if community.isEmpty {
            let hi = max(hole[0].rank, hole[1].rank), lo = min(hole[0].rank, hole[1].rank)
            var s = Double(hi) / 14 * 0.45 + Double(lo) / 14 * 0.15
            if hole[0].rank == hole[1].rank { s += 0.34 + Double(hi) / 14 * 0.1 }
            if hole[0].suit == hole[1].suit { s += 0.07 }
            if abs(hole[0].rank - hole[1].rank) == 1 { s += 0.05 }
            return min(1, s)
        } else {
            let category = HandEval.best7(hole + community)[0]   // 0...8
            return min(1, Double(category) / 8 + 0.06)
        }
    }

    // MARK: - Sound

    private func play(_ name: String) {
        guard soundOn else { return }
        NSSound(named: name)?.play()
    }
}

// MARK: - 7-card hand evaluation

enum HandEval {
    /// Comparable score: [category, tiebreakers…]. Higher is better.
    static func evaluate5(_ cards: [Card]) -> [Int] {
        let ranksDesc = cards.map { $0.rank }.sorted(by: >)
        let isFlush = Set(cards.map { $0.suit }).count == 1

        var counts: [Int: Int] = [:]
        cards.forEach { counts[$0.rank, default: 0] += 1 }
        let ordered = counts.keys.sorted { (counts[$0]!, $0) > (counts[$1]!, $1) }
        let pattern = ordered.map { counts[$0]! }

        var straightHigh = 0
        if Set(ranksDesc).count == 5 {
            let s = ranksDesc.sorted()
            if s[4] - s[0] == 4 { straightHigh = s[4] }
            else if Set(s) == Set([14, 2, 3, 4, 5]) { straightHigh = 5 }
        }
        let isStraight = straightHigh != 0

        if isStraight && isFlush { return [8, straightHigh] }
        if pattern[0] == 4 { return [7, ordered[0], ordered[1]] }
        if pattern[0] == 3 && pattern.count > 1 && pattern[1] >= 2 { return [6, ordered[0], ordered[1]] }
        if isFlush { return [5] + ranksDesc }
        if isStraight { return [4, straightHigh] }
        if pattern[0] == 3 { return [3, ordered[0]] + Array(ordered.dropFirst().prefix(2)) }
        if pattern[0] == 2 && pattern.count > 1 && pattern[1] == 2 { return [2, ordered[0], ordered[1], ordered[2]] }
        if pattern[0] == 2 { return [1, ordered[0]] + Array(ordered.dropFirst().prefix(3)) }
        return [0] + ranksDesc
    }

    static func best7(_ cards: [Card]) -> [Int] {
        guard cards.count > 5 else { return evaluate5(cards) }
        var best: [Int] = [-1]
        for combo in combinations(cards.count, 5) {
            let hand = combo.map { cards[$0] }
            let s = evaluate5(hand)
            if compare(s, best) > 0 { best = s }
        }
        return best
    }

    static func compare(_ a: [Int], _ b: [Int]) -> Int {
        for i in 0..<min(a.count, b.count) where a[i] != b[i] { return a[i] > b[i] ? 1 : -1 }
        if a.count != b.count { return a.count > b.count ? 1 : -1 }
        return 0
    }

    static func name(_ score: [Int]) -> String {
        switch score.first ?? 0 {
        case 8: return score.count > 1 && score[1] == 14 ? "Royal Flush" : "Straight Flush"
        case 7: return "Four of a Kind"
        case 6: return "Full House"
        case 5: return "Flush"
        case 4: return "Straight"
        case 3: return "Three of a Kind"
        case 2: return "Two Pair"
        case 1: return "Pair"
        default: return "High Card"
        }
    }

    private static func combinations(_ n: Int, _ k: Int) -> [[Int]] {
        var result: [[Int]] = []
        var combo: [Int] = []
        func helper(_ start: Int) {
            if combo.count == k { result.append(combo); return }
            for i in start..<n {
                combo.append(i); helper(i + 1); combo.removeLast()
            }
        }
        helper(0)
        return result
    }
}

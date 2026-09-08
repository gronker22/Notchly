//
//  BlackjackGame.swift
//  Notchly — Blackjack
//
//  Single-player blackjack vs. the dealer with: multi-deck shoe, soft-17 rule
//  toggle, double down, surrender, insurance, all-in, Hi-Lo running count, and
//  persistent stats (hands, win rate, biggest win/loss, streak).
//

import Foundation
import Combine
import SwiftUI

struct Card: Identifiable, Equatable {
    enum Suit: String, CaseIterable {
        case spades = "♠", hearts = "♥", diamonds = "♦", clubs = "♣"
        var isRed: Bool { self == .hearts || self == .diamonds }
    }
    let id = UUID()
    let rank: Int          // 2...14  (11=J, 12=Q, 13=K, 14=A)
    let suit: Suit

    var label: String {
        switch rank {
        case 11: return "J"; case 12: return "Q"; case 13: return "K"; case 14: return "A"
        default: return "\(rank)"
        }
    }
    var value: Int {
        if rank == 14 { return 11 }
        if rank >= 11 { return 10 }
        return rank
    }
}

@MainActor
final class BlackjackGame: ObservableObject {

    enum Phase { case betting, dealing, insurance, playerTurn, dealerTurn, result }
    enum Outcome { case none, win, lose, push, gameOver }

    private let dealAnim = Animation.spring(response: 0.55, dampingFraction: 0.78)

    // Cards
    @Published private(set) var player: [Card] = []
    @Published private(set) var dealer: [Card] = []
    @Published private(set) var dealerHoleHidden = true
    @Published private(set) var phase: Phase = .betting

    // Money
    @Published private(set) var chips: Int {
        didSet { defaults.set(chips, forKey: K.chips); if chips > highScore { highScore = chips } }
    }
    @Published private(set) var highScore: Int { didSet { defaults.set(highScore, forKey: K.high) } }
    @Published private(set) var bet: Int = 25
    @Published private(set) var message: String = "Place your bet"
    @Published private(set) var outcome: Outcome = .none

    // Settings
    @Published var deckCount: Int { didSet { defaults.set(deckCount, forKey: K.decks); buildDeck() } }
    @Published var dealerHitsSoft17: Bool { didSet { defaults.set(dealerHitsSoft17, forKey: K.h17) } }
    @Published var showCount: Bool { didSet { defaults.set(showCount, forKey: K.showCount) } }

    // Counting
    @Published private(set) var runningCount = 0

    // Stats
    @Published private(set) var handsPlayed = 0
    @Published private(set) var wins = 0
    @Published private(set) var losses = 0
    @Published private(set) var pushes = 0
    @Published private(set) var biggestWin = 0
    @Published private(set) var biggestLoss = 0
    @Published private(set) var streak = 0          // + = win streak, − = loss streak

    // Wager bookkeeping
    private var doubled = false
    private var insuranceBet = 0
    private var chipsAtHandStart = 0
    private var actedThisHand = false               // hit/double taken → no surrender

    private var deck: [Card] = []
    private let defaults = UserDefaults.standard
    private enum K {
        static let chips = "notchly.bj.chips", high = "notchly.bj.high"
        static let decks = "notchly.bj.decks", h17 = "notchly.bj.h17", showCount = "notchly.bj.showcount"
        static let hands = "notchly.bj.hands", wins = "notchly.bj.wins", losses = "notchly.bj.losses"
        static let pushes = "notchly.bj.pushes", bigWin = "notchly.bj.bigwin", bigLoss = "notchly.bj.bigloss"
        static let streak = "notchly.bj.streak"
    }

    init() {
        let saved = defaults.object(forKey: K.chips) as? Int
        let start = (saved == nil || saved! <= 0) ? 500 : saved!
        chips = start
        highScore = max(defaults.integer(forKey: K.high), start)
        let d = defaults.integer(forKey: K.decks)
        deckCount = [1, 2, 4, 6, 8].contains(d) ? d : 6
        dealerHitsSoft17 = defaults.bool(forKey: K.h17)
        showCount = defaults.bool(forKey: K.showCount)
        handsPlayed = defaults.integer(forKey: K.hands)
        wins = defaults.integer(forKey: K.wins)
        losses = defaults.integer(forKey: K.losses)
        pushes = defaults.integer(forKey: K.pushes)
        biggestWin = defaults.integer(forKey: K.bigWin)
        biggestLoss = defaults.integer(forKey: K.bigLoss)
        streak = defaults.integer(forKey: K.streak)
        buildDeck()
    }

    // MARK: - Derived

    var stake: Int { bet * (doubled ? 2 : 1) }
    var playerValue: Int { value(player) }
    var dealerVisibleValue: Int { dealerHoleHidden ? value(Array(dealer.dropFirst())) : value(dealer) }
    var canDouble: Bool { phase == .playerTurn && player.count == 2 && !doubled && chips >= bet }
    var canSurrender: Bool { phase == .playerTurn && player.count == 2 && !actedThisHand }
    var winRate: Double { handsPlayed == 0 ? 0 : Double(wins) / Double(handsPlayed) }

    // MARK: - Deck / counting

    private func buildDeck() {
        deck = []
        for _ in 0..<max(1, deckCount) {
            for s in Card.Suit.allCases { for r in 2...14 { deck.append(Card(rank: r, suit: s)) } }
        }
        deck.shuffle()
        runningCount = 0
    }

    private func draw() -> Card {
        if deck.count < max(15, deckCount * 13) { buildDeck() }   // reshuffle ~75% penetration
        return deck.removeLast()
    }

    private func countCard(_ c: Card) {
        if c.rank <= 6 { runningCount += 1 }
        else if c.rank >= 10 { runningCount -= 1 }
    }

    func value(_ hand: [Card]) -> Int {
        var total = hand.reduce(0) { $0 + $1.value }
        var aces = hand.filter { $0.rank == 14 }.count
        while total > 21 && aces > 0 { total -= 10; aces -= 1 }
        return total
    }

    private func isSoft(_ hand: [Card]) -> Bool {
        var total = hand.reduce(0) { $0 + $1.value }
        var aces = hand.filter { $0.rank == 14 }.count
        while total > 21 && aces > 0 { total -= 10; aces -= 1 }
        return aces > 0
    }

    // MARK: - Betting

    func adjustBet(_ delta: Int) {
        guard phase == .betting || phase == .result else { return }
        bet = min(max(5, bet + delta), max(5, chips))
    }
    func allIn() {
        guard phase == .betting || phase == .result else { return }
        bet = max(5, chips)
    }

    // MARK: - Deal

    func deal() async {
        guard phase == .betting || phase == .result else { return }
        guard chips >= bet else { message = "Not enough chips"; return }

        chipsAtHandStart = chips
        chips -= bet
        doubled = false; insuranceBet = 0; actedThisHand = false
        withAnimation(.easeOut(duration: 0.2)) { player = []; dealer = [] }
        dealerHoleHidden = true
        phase = .dealing; message = "Dealing…"; outcome = .none
        try? await Task.sleep(nanoseconds: 180_000_000)

        await dealOne(toPlayer: true, count: true)
        await dealOne(toPlayer: false, count: false)   // dealer hole — counted on reveal
        await dealOne(toPlayer: true, count: true)
        await dealOne(toPlayer: false, count: true)    // dealer up card

        if dealer[1].rank == 14 {                       // up card is Ace → insurance
            phase = .insurance
            message = "Dealer shows Ace — Insurance?"
            return
        }
        resolveNaturalsOrPlay()
    }

    private func dealOne(toPlayer: Bool, count: Bool) async {
        let card = draw()
        withAnimation(dealAnim) { if toPlayer { player.append(card) } else { dealer.append(card) } }
        if count { countCard(card) }
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    private func resolveNaturalsOrPlay() {
        let pBJ = value(player) == 21
        let dBJ = value(dealer) == 21
        if pBJ || dBJ {
            if pBJ && dBJ { chips += bet; finish("Push — both blackjack") }
            else if pBJ { chips += bet + Int(Double(bet) * 1.5); finish("Blackjack! You win") }
            else { finish("Dealer blackjack — you lose") }
        } else {
            phase = .playerTurn; message = "Your move"
        }
    }

    // MARK: - Insurance

    func takeInsurance() {
        guard phase == .insurance else { return }
        insuranceBet = bet / 2
        chips -= insuranceBet
        resolveInsurance()
    }
    func declineInsurance() {
        guard phase == .insurance else { return }
        resolveInsurance()
    }
    private func resolveInsurance() {
        if value(dealer) == 21 {
            if insuranceBet > 0 { chips += insuranceBet * 3 }   // pays 2:1
            if value(player) == 21 { chips += bet }             // main pushes
            finish(insuranceBet > 0 ? "Dealer blackjack — insurance pays" : "Dealer blackjack")
        } else {
            resolveNaturalsOrPlay()
        }
    }

    // MARK: - Player actions

    func hit() {
        guard phase == .playerTurn else { return }
        actedThisHand = true
        withAnimation(dealAnim) { player.append(draw()) }
        if let c = player.last { countCard(c) }
        let v = value(player)
        if v > 21 { finish("Bust! You lose") }
        else if v == 21 { Task { await dealerPlay() } }
    }

    func stand() async {
        guard phase == .playerTurn else { return }
        await dealerPlay()
    }

    func doubleDown() async {
        guard canDouble else { return }
        chips -= bet
        doubled = true
        actedThisHand = true
        withAnimation(dealAnim) { player.append(draw()) }
        if let c = player.last { countCard(c) }
        if value(player) > 21 { finish("Bust! You lose") }
        else { await dealerPlay() }
    }

    func surrender() {
        guard canSurrender else { return }
        chips += bet / 2
        finish("Surrendered")
    }

    // MARK: - Dealer

    private func dealerPlay() async {
        phase = .dealerTurn
        revealHole()
        try? await Task.sleep(nanoseconds: 500_000_000)
        while dealerShouldHit() {
            withAnimation(dealAnim) { dealer.append(draw()) }
            if let c = dealer.last { countCard(c) }
            try? await Task.sleep(nanoseconds: 450_000_000)
        }
        settle()
    }

    private func dealerShouldHit() -> Bool {
        let v = value(dealer)
        if v < 17 { return true }
        if v == 17 && dealerHitsSoft17 && isSoft(dealer) { return true }
        return false
    }

    private func revealHole() {
        guard dealerHoleHidden else { return }
        withAnimation(.easeInOut(duration: 0.45)) { dealerHoleHidden = false }
        if let hole = dealer.first { countCard(hole) }
    }

    private func settle() {
        let p = value(player), d = value(dealer)
        if d > 21 { chips += stake * 2; finish("Dealer busts — you win") }
        else if p > d { chips += stake * 2; finish("You win") }
        else if p == d { chips += stake; finish("Push") }
        else { finish("You lose") }
    }

    // MARK: - Finish + stats

    private func finish(_ msg: String) {
        revealHole()
        phase = .result
        let delta = chips - chipsAtHandStart

        if chips <= 0 { message = "GAME OVER"; outcome = .gameOver }
        else {
            message = msg
            outcome = delta > 0 ? .win : (delta < 0 ? .lose : .push)
        }

        handsPlayed += 1
        if delta > 0 {
            wins += 1
            streak = streak > 0 ? streak + 1 : 1
            biggestWin = max(biggestWin, delta)
        } else if delta < 0 {
            losses += 1
            streak = streak < 0 ? streak - 1 : -1
            biggestLoss = max(biggestLoss, -delta)
        } else {
            pushes += 1
        }
        saveStats()
        bet = min(bet, max(5, chips))
    }

    private func saveStats() {
        defaults.set(handsPlayed, forKey: K.hands)
        defaults.set(wins, forKey: K.wins)
        defaults.set(losses, forKey: K.losses)
        defaults.set(pushes, forKey: K.pushes)
        defaults.set(biggestWin, forKey: K.bigWin)
        defaults.set(biggestLoss, forKey: K.bigLoss)
        defaults.set(streak, forKey: K.streak)
    }

    func resetStats() {
        handsPlayed = 0; wins = 0; losses = 0; pushes = 0
        biggestWin = 0; biggestLoss = 0; streak = 0
        saveStats()
    }

    func reload() {
        chips = 500; bet = 25; phase = .betting
        player = []; dealer = []
        message = "New game — place your bet"; outcome = .none
    }
}

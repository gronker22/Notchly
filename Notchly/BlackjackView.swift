//
//  BlackjackView.swift
//  Notchly — Blackjack UI
//
//  A small green-felt blackjack table, opened in its own window from the panel
//  footer via BlackjackWindowPresenter.
//

import SwiftUI
import AppKit

struct BlackjackView: View {
    @ObservedObject var game: BlackjackGame
    @State private var showSlot = false

    var body: some View {
        VStack(spacing: 14) {
            topBar

            // Dealer
            handSection(
                title: "Dealer",
                value: game.dealerHoleHidden ? nil : game.value(game.dealer),
                cards: game.dealer,
                hideFirst: game.dealerHoleHidden
            )

            Rectangle().fill(.white.opacity(0.15)).frame(height: 1)

            // Player
            handSection(
                title: "You",
                value: game.player.isEmpty ? nil : game.playerValue,
                cards: game.player,
                hideFirst: false
            )

            messageView

            coachHint

            if game.bonusAvailable {
                Button { showSlot = true } label: {
                    Label("Bonus Spin", systemImage: "dice.fill")
                        .font(.system(.subheadline, design: .rounded).weight(.bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Capsule().fill(.yellow))
                }
                .buttonStyle(.plain)
            }

            controls

            statsAndSettings
        }
        .padding(20)
        .frame(width: 420, height: 600)
        .background(FeltBackground())
        .sheet(isPresented: $showSlot) {
            SlotMachineView(onReward: { game.awardBonus($0) },
                            onClose: { showSlot = false; game.clearBonus() })
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            Label("\(game.chips)", systemImage: "dollarsign.circle.fill")
                .font(.system(.title3, design: .rounded).weight(.bold))
                .foregroundStyle(.yellow)
            if game.showCount {
                Text("Count \(game.runningCount >= 0 ? "+" : "")\(game.runningCount)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.cyan)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(.black.opacity(0.25)))
            }
            Spacer()
            // AI coach on/off
            Button { game.showHint.toggle() } label: {
                Image(systemName: game.showHint ? "lightbulb.fill" : "lightbulb.slash")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(game.showHint ? .yellow : .white.opacity(0.5))
            }
            .buttonStyle(.plain)
            Label("\(game.highScore)", systemImage: "trophy.fill")
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .foregroundStyle(.orange)
        }
    }

    // MARK: Message (outcome-styled)

    private var messageView: some View {
        let loss = game.outcome == .lose || game.outcome == .gameOver
        return Text(game.message)
            .font(.system(game.outcome == .gameOver ? .title : (loss ? .title2 : .subheadline),
                          design: .rounded).weight(.bold))
            .foregroundStyle(messageColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, loss ? 8 : 2)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(loss ? Color.red.opacity(0.22) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(loss ? Color.red.opacity(0.7) : Color.clear, lineWidth: 1.5)
            )
            .id(game.message)                                  // re-trigger transition per result
            .transition(.scale.combined(with: .opacity))
            .animation(.spring(response: 0.35, dampingFraction: 0.6), value: game.message)
    }

    private var messageColor: Color {
        switch game.outcome {
        case .win:  return .green
        case .lose, .gameOver: return .red
        case .push: return .yellow
        case .none: return .white
        }
    }

    // MARK: Hand section

    private func handSection(title: String, value: Int?, cards: [Card], hideFirst: Bool) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                if let value {
                    Text("(\(value))")
                        .font(.system(.caption, design: .rounded).weight(.bold))
                        .foregroundStyle(value > 21 ? .red : .white)
                }
            }
            HStack(spacing: 6) {
                if cards.isEmpty {
                    CardBack().opacity(0.25)
                } else {
                    ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                        FlippableCard(card: card, faceUp: !(hideFirst && index == 0))
                            // Slides down from the deck + fades in as it's dealt.
                            // The deal sequence (in the game) drives the timing.
                            .transition(.asymmetric(
                                insertion: .move(edge: .top)
                                    .combined(with: .opacity)
                                    .combined(with: .scale(scale: 0.85)),
                                removal: .opacity))
                    }
                }
            }
            .frame(height: 74)
        }
    }

    // MARK: Controls

    @ViewBuilder
    private var coachHint: some View {
        if game.showHint, let action = game.recommendedAction {
            HStack(spacing: 6) {
                Image(systemName: "lightbulb.fill").font(.system(size: 10))
                Text("Basic strategy: \(action.label)")
                    .font(.system(.caption, design: .rounded).weight(.bold))
            }
            .foregroundStyle(.yellow)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(.yellow.opacity(0.14)))
            .frame(height: 22)
        } else {
            Color.clear.frame(height: 22)
        }
    }

    @ViewBuilder
    private var controls: some View {
        if game.chips <= 0 && game.phase != .playerTurn {
            gameButton("New Game (+500)", tint: .yellow) { game.reload() }
        } else {
            switch game.phase {
            case .betting, .result:
                VStack(spacing: 8) {
                    HStack(spacing: 12) {
                        chipButton("-") { game.adjustBet(-5) }
                        VStack(spacing: 6) {
                            gameButton("Deal", tint: .green) { Task { await game.deal() } }
                            Text("Bet \(game.bet)")
                                .font(.system(.subheadline, design: .rounded).weight(.bold))
                                .foregroundStyle(.yellow)
                        }
                        chipButton("+") { game.adjustBet(5) }
                    }
                    Button("All in") { game.allIn() }
                        .font(.system(.caption, design: .rounded).weight(.bold))
                        .foregroundStyle(.red)
                        .buttonStyle(.plain)
                }
            case .insurance:
                HStack(spacing: 10) {
                    gameButton("Insure", tint: .blue) { game.takeInsurance() }
                    gameButton("No", tint: .gray) { game.declineInsurance() }
                }
            case .playerTurn:
                HStack(spacing: 8) {
                    gameButton("Hit", tint: .blue) { game.hit() }
                    gameButton("Stand", tint: .orange) { Task { await game.stand() } }
                    if game.canDouble {
                        gameButton("Double", tint: .purple) { Task { await game.doubleDown() } }
                    }
                    if game.canSurrender {
                        gameButton("Surr.", tint: .gray) { game.surrender() }
                    }
                }
            case .dealing:
                Text("Dealing…")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
            case .dealerTurn:
                Text("Dealer playing…")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    // MARK: Stats & settings

    @State private var showPanel = false

    private var statsAndSettings: some View {
        VStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showPanel.toggle() }
            } label: {
                HStack {
                    Image(systemName: "chart.bar.fill")
                    Text("Stats & Settings")
                    Spacer()
                    Image(systemName: showPanel ? "chevron.up" : "chevron.down")
                }
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)

            if showPanel {
                VStack(alignment: .leading, spacing: 8) {
                    // Stats grid
                    HStack {
                        stat("Hands", "\(game.handsPlayed)")
                        stat("Win rate", String(format: "%.0f%%", game.winRate * 100))
                        stat("Streak", streakText)
                    }
                    HStack {
                        stat("Best win", "+\(game.biggestWin)")
                        stat("Worst loss", "-\(game.biggestLoss)")
                        stat("W/L/P", "\(game.wins)/\(game.losses)/\(game.pushes)")
                    }

                    Divider().overlay(.white.opacity(0.2))

                    // Settings
                    HStack {
                        Text("Decks").font(.caption).foregroundStyle(.white.opacity(0.7))
                        Spacer()
                        Picker("", selection: deckBinding) {
                            ForEach([1, 2, 4, 6, 8], id: \.self) { Text("\($0)").tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 70)
                        .disabled(game.phase != .betting && game.phase != .result)
                    }
                    Toggle("Dealer hits soft 17", isOn: Binding(
                        get: { game.dealerHitsSoft17 }, set: { game.dealerHitsSoft17 = $0 }))
                    Toggle("Show card count", isOn: Binding(
                        get: { game.showCount }, set: { game.showCount = $0 }))
                    Toggle("Strategy hints (coach)", isOn: Binding(
                        get: { game.showHint }, set: { game.showHint = $0 }))

                    Button("Reset stats") { game.resetStats() }
                        .font(.caption).foregroundStyle(.red).buttonStyle(.plain)
                }
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.white)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.2)))
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
        }
    }

    private var deckBinding: Binding<Int> {
        Binding(get: { game.deckCount }, set: { game.deckCount = $0 })
    }

    private var streakText: String {
        if game.streak > 0 { return "W\(game.streak)" }
        if game.streak < 0 { return "L\(-game.streak)" }
        return "—"
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(.subheadline, design: .rounded).weight(.bold))
            Text(label).font(.system(size: 8, design: .rounded)).foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity)
    }

    private func gameButton(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(.body, design: .rounded).weight(.bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Capsule().fill(tint.opacity(0.85)))
        }
        .buttonStyle(.plain)
    }

    private func chipButton(_ s: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(s)
                .font(.system(.title3, design: .rounded).weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(.white.opacity(0.18)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Card views

/// Shows a card that flips between its back and face with a 3D rotation.
struct FlippableCard: View {
    let card: Card
    let faceUp: Bool

    var body: some View {
        ZStack {
            CardFace(card: card)
                .opacity(faceUp ? 1 : 0)
            CardBack()
                .opacity(faceUp ? 0 : 1)
        }
        .rotation3DEffect(.degrees(faceUp ? 0 : 180), axis: (x: 0, y: 1, z: 0))
        .animation(.easeInOut(duration: 0.45), value: faceUp)
    }
}

struct CardFace: View {
    let card: Card
    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(.white)
            .frame(width: 50, height: 70)
            .overlay(
                VStack(spacing: 2) {
                    Text(card.label)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text(card.suit.rawValue)
                        .font(.system(size: 18))
                }
                .foregroundStyle(card.suit.isRed ? Color.red : Color.black)
            )
            .shadow(color: .black.opacity(0.45), radius: 4, y: 3)
    }
}

struct CardBack: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.2, green: 0.3, blue: 0.7),
                                          Color(red: 0.12, green: 0.18, blue: 0.5)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 50, height: 70)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(.white.opacity(0.5), lineWidth: 1.5)
                    .padding(4)
            )
            .shadow(color: .black.opacity(0.45), radius: 4, y: 3)
    }
}

// MARK: - Window presenter

@MainActor
enum BlackjackWindowPresenter {
    private static var window: NSWindow?
    private static let game = BlackjackGame()

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = GameWindow.make(title: "Blackjack", design: CGSize(width: 420, height: 600)) {
            BlackjackView(game: game)
        }
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

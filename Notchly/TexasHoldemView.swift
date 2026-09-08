//
//  TexasHoldemView.swift
//  Notchly — Texas Hold'em UI
//
//  Compact dark poker table: two AI seats up top, community cards + pot in the
//  middle, your seat at the bottom, and contextual action buttons.
//

import SwiftUI
import AppKit

struct TexasHoldemView: View {
    @ObservedObject var game: TexasHoldemGame
    @State private var raiseAmount: Double = 0
    @State private var showPanel = false

    var body: some View {
        VStack(spacing: 10) {
            // AI opponents (4, in two rows)
            VStack(spacing: 6) {
                HStack(alignment: .top, spacing: 24) {
                    seat(game.players[1], compact: true)
                    seat(game.players[2], compact: true)
                }
                HStack(alignment: .top, spacing: 24) {
                    seat(game.players[3], compact: true)
                    seat(game.players[4], compact: true)
                }
            }
            .padding(.top, 4)

            // Pot + community
            VStack(spacing: 8) {
                Text("POT \(game.pot)")
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .foregroundStyle(.yellow)
                    .contentTransition(.numericText())
                    .animation(.spring(response: 0.4), value: game.pot)
                communityRow
            }
            .padding(.vertical, 6)

            // Live stats overlay (win %, hand strength, pot odds)
            if game.isBetting && !game.players[0].folded {
                liveHUD
            }

            Rectangle().fill(.white.opacity(0.1)).frame(height: 1)

            // You
            seat(game.players[0])

            // Message / result
            Text(game.resultText.isEmpty ? game.message : game.resultText)
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .lineLimit(2)

            actions

            settingsPanel
        }
        .padding(16)
        .frame(width: 460, height: 760)
        .background(feltBackground)
        .onChange(of: game.isYourTurn) { _, yours in
            if yours { raiseAmount = Double(game.minRaiseTo) }
        }
    }

    // MARK: Felt + HUD

    private var feltBackground: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.05, green: 0.32, blue: 0.17),
                                    Color(red: 0.02, green: 0.16, blue: 0.10)],
                           startPoint: .top, endPoint: .bottom)
            // Subtle felt "spotlight" in the centre.
            RadialGradient(colors: [Color.white.opacity(0.07), .clear],
                           center: .center, startRadius: 8, endRadius: 280)
            // Vignette.
            RadialGradient(colors: [.clear, Color.black.opacity(0.35)],
                           center: .center, startRadius: 180, endRadius: 420)
        }
        .ignoresSafeArea()
    }

    private var liveHUD: some View {
        HStack(spacing: 10) {
            meter("Hand", game.winProbability, .green)
            meter("Pot odds", game.potOddsForYou, .orange)
            if game.toCallForYou > 0 {
                Text(game.winProbability >= game.potOddsForYou ? "+EV" : "−EV")
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .foregroundStyle(game.winProbability >= game.potOddsForYou ? .green : .red)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.25)))
    }

    private func meter(_ label: String, _ value: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.system(size: 8, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                Text("\(Int(value * 100))%")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(color)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Capsule().fill(color)
                        .frame(width: max(2, geo.size.width * value))
                }
            }
            .frame(height: 5)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Seat

    private func seat(_ p: TexasHoldemGame.Player, compact: Bool = false) -> some View {
        let isWinner = game.winnerSeats.contains(p.id)
        return VStack(spacing: 4) {
            // Position marker (D / SB / BB) + avatar + name
            HStack(spacing: 4) {
                positionTag(p)
                Image(systemName: p.avatar)
                    .font(.system(size: 13))
                    .foregroundStyle(game.current == p.id ? .yellow : .white.opacity(0.85))
                Text(p.name)
                    .font(.system(.caption, design: .rounded).weight(.bold))
                    .foregroundStyle(game.current == p.id ? .yellow : .white)
            }

            // Last-action badge
            actionBadge(p)

            // Hole cards (fold = slide down + fade out)
            HStack(spacing: compact ? 3 : 4) {
                ForEach(p.hole) { card in
                    Group {
                        if p.isAI && !game.revealAll {
                            CardBack()
                        } else {
                            FlippableCard(card: card, faceUp: true)
                        }
                    }
                    .scaleEffect(compact ? 0.66 : 1, anchor: .center)
                    .frame(width: compact ? 34 : 50, height: compact ? 47 : 70)
                    .transition(.move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.8)))
                }
            }
            .opacity(p.folded ? 0 : 1)
            .offset(y: p.folded ? 20 : 0)
            .animation(.easeInOut(duration: 0.3), value: p.folded)

            // Chips + current bet
            HStack(spacing: 6) {
                Label("\(p.chips)", systemImage: "dollarsign.circle.fill")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.yellow)
                if p.bet > 0 {
                    Text("• \(p.bet)")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

            // Thinking progress bar while this AI decides
            if game.current == p.id && p.isAI && game.isBetting {
                ThinkingBar().frame(width: 70)
            } else {
                Color.clear.frame(width: 70, height: 3)
            }
        }
        .frame(width: compact ? 132 : 176)        // fixed width so seats don't jitter
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isWinner ? Color.yellow.opacity(0.10) : .clear)
        )
        .modifier(WinnerGlow(active: isWinner))
    }

    @ViewBuilder
    private func positionTag(_ p: TexasHoldemGame.Player) -> some View {
        if game.dealerButton == p.id {
            blindTag("D", bg: .white, fg: .black)
        } else if game.smallBlindSeat == p.id {
            blindTag("SB", bg: .blue, fg: .white)
        } else if game.bigBlindSeat == p.id {
            blindTag("BB", bg: .orange, fg: .white)
        } else {
            Color.clear.frame(width: 16, height: 14)
        }
    }

    private func blindTag(_ text: String, bg: Color, fg: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .black, design: .rounded))
            .foregroundStyle(fg)
            .frame(minWidth: 16, minHeight: 14)
            .padding(.horizontal, 2)
            .background(Capsule().fill(bg))
    }

    @ViewBuilder
    private func actionBadge(_ p: TexasHoldemGame.Player) -> some View {
        if p.lastAction.isEmpty {
            Color.clear.frame(height: 14)
        } else {
            let word = p.lastAction.split(separator: " ").first.map(String.init) ?? p.lastAction
            Text(word.uppercased())
                .font(.system(size: 8, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(badgeColor(word).opacity(0.9)))
                .frame(height: 14)
        }
    }

    private func badgeColor(_ word: String) -> Color {
        switch word.lowercased() {
        case "fold": return .red
        case "raise", "all-in": return .green
        case "call": return .blue
        case "check": return .gray
        default: return .purple
        }
    }

    // MARK: Community

    private var communityRow: some View {
        HStack(spacing: 5) {
            ForEach(0..<5, id: \.self) { i in
                if i < game.community.count {
                    FlippableCard(card: game.community[i], faceUp: true)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    CardBack().opacity(0.18)
                }
            }
        }
        .frame(height: 72)
    }

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        if game.isYourTurn {
            VStack(spacing: 8) {
                if game.maxRaiseTo > game.minRaiseTo {
                    HStack(spacing: 8) {
                        Text("Raise \(Int(raiseAmount))")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white).frame(width: 80, alignment: .leading)
                        Slider(value: $raiseAmount,
                               in: Double(game.minRaiseTo)...Double(game.maxRaiseTo))
                        .tint(.green)
                    }
                }
                HStack(spacing: 8) {
                    actionButton("Fold", .red) { game.youFold() }
                    actionButton(game.canCheck ? "Check" : "Call \(game.toCallForYou)", .blue) { game.youCheckCall() }
                    if game.maxRaiseTo > game.minRaiseTo {
                        actionButton("Raise", .green) { game.youRaise(to: Int(raiseAmount)) }
                    }
                    actionButton("All-in", .orange) { game.youAllIn() }
                }
            }
        } else if game.stage == .idle || game.stage == .handOver {
            if game.you.chips < game.bigBlind && game.stage == .handOver {
                actionButton("New Game (+1000)", .yellow) { game.newGame() }
            } else {
                actionButton(game.stage == .idle ? "Deal" : "Next Hand", .green) {
                    Task { await game.startHand() }
                }
            }
        } else {
            Text("\(game.players[game.current].name) is thinking…")
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    private func actionButton(_ title: String, _ tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(Capsule().fill(tint.opacity(0.85)))
        }
        .buttonStyle(.plain)
    }

    // MARK: Settings / stats

    private var settingsPanel: some View {
        VStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showPanel.toggle() }
            } label: {
                HStack {
                    Image(systemName: "slider.horizontal.3")
                    Text("Stats & Settings")
                    Spacer()
                    Text("W \(game.wins) · L \(game.losses) · Pot \(game.biggestPot)")
                    Image(systemName: showPanel ? "chevron.up" : "chevron.down")
                }
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.65))
            }
            .buttonStyle(.plain)

            if showPanel {
                VStack(spacing: 8) {
                    Picker("Difficulty", selection: Binding(
                        get: { game.difficulty },
                        set: { game.difficulty = $0 })) {
                            Text("Easy").tag(TexasHoldemGame.Difficulty.easy)
                            Text("Hard").tag(TexasHoldemGame.Difficulty.hard)
                        }
                        .pickerStyle(.segmented)
                    Toggle("Sound effects", isOn: Binding(
                        get: { game.soundOn }, set: { game.soundOn = $0 }))
                        .toggleStyle(.switch).controlSize(.mini)
                    Button("Reset stats") { game.resetStats() }
                        .font(.caption).foregroundStyle(.red).buttonStyle(.plain)
                }
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.white)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.2)))
            }
        }
    }
}

// MARK: - Thinking progress bar

struct ThinkingBar: View {
    @State private var progress: CGFloat = 0
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Capsule().fill(.cyan).frame(width: geo.size.width * progress)
            }
        }
        .frame(height: 3)
        .onAppear {
            progress = 0
            withAnimation(.linear(duration: 0.7)) { progress = 1 }
        }
    }
}

// MARK: - Winner spotlight glow / pulse

struct WinnerGlow: ViewModifier {
    let active: Bool
    @State private var pulse = false
    func body(content: Content) -> some View {
        content
            .shadow(color: .yellow.opacity(active ? (pulse ? 0.9 : 0.25) : 0),
                    radius: active ? 16 : 0)
            .scaleEffect(active && pulse ? 1.04 : 1.0)
            .onChange(of: active) { _, on in
                if on {
                    withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
                } else {
                    pulse = false
                }
            }
    }
}

// MARK: - Window presenter

@MainActor
enum HoldemWindowPresenter {
    private static var window: NSWindow?
    private static let game = TexasHoldemGame()

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 760),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "Texas Hold'em"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: TexasHoldemView(game: game))
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

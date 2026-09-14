//
//  ChessView.swift
//  Notchly — Chess UI + game controller
//

import SwiftUI
import AppKit
import Combine

// MARK: - Controller

@MainActor
final class ChessGame: ObservableObject {
    enum Status: Equatable { case playing, checkmate(winner: ChessColor), stalemate, draw }
    enum Difficulty: String, CaseIterable, Identifiable {
        case easy, medium, hard
        var id: String { rawValue }
        var depth: Int { self == .easy ? 2 : self == .medium ? 3 : 4 }
        var label: String { rawValue.capitalized }
    }

    @Published private(set) var position = Position.initial
    @Published private(set) var status: Status = .playing
    @Published private(set) var selected: Int?
    @Published private(set) var legalTargets: Set<Int> = []
    @Published private(set) var lastMove: ChessMove?
    @Published private(set) var message = "Your move"
    @Published private(set) var thinking = false
    @Published var pendingPromotion: PendingPromotion?
    @Published var difficulty: Difficulty = .medium
    @Published private(set) var wins = 0
    @Published private(set) var losses = 0
    @Published private(set) var draws = 0

    struct PendingPromotion { let from: Int; let to: Int }

    let humanColor: ChessColor = .white
    private let defaults = UserDefaults.standard

    init() {
        wins = defaults.integer(forKey: "notchly.chess.wins")
        losses = defaults.integer(forKey: "notchly.chess.losses")
        draws = defaults.integer(forKey: "notchly.chess.draws")
    }

    var inCheckSquare: Int? {
        position.isInCheck(position.side) ? position.kingSquare(position.side) : nil
    }

    func newGame() {
        position = .initial
        status = .playing
        selected = nil
        legalTargets = []
        lastMove = nil
        pendingPromotion = nil
        thinking = false
        message = "Your move"
    }

    func tap(_ sq: Int) {
        guard status == .playing, position.side == humanColor, !thinking, pendingPromotion == nil else { return }
        if let sel = selected {
            if sq == sel { clearSelection(); return }
            let candidates = legalFrom(sel).filter { $0.to == sq }
            if !candidates.isEmpty {
                if candidates.contains(where: { $0.isPromotion }) {
                    pendingPromotion = PendingPromotion(from: sel, to: sq)
                } else {
                    apply(candidates[0]); afterHuman()
                }
                clearSelection(); return
            }
        }
        if let p = position.squares[sq], p.color == humanColor {
            selected = sq
            legalTargets = Set(legalFrom(sq).map { $0.to })
        } else {
            clearSelection()
        }
    }

    func completePromotion(_ kind: PieceKind) {
        guard let pp = pendingPromotion else { return }
        if let m = legalFrom(pp.from).first(where: { $0.to == pp.to && $0.promotion == kind }) {
            apply(m); afterHuman()
        }
        pendingPromotion = nil
    }

    private func legalFrom(_ sq: Int) -> [ChessMove] { position.legalMoves().filter { $0.from == sq } }
    private func clearSelection() { selected = nil; legalTargets = [] }

    private func apply(_ m: ChessMove) {
        position = position.makeRaw(m)
        lastMove = m
        updateStatus()
    }

    private func afterHuman() {
        guard status == .playing else { return }
        triggerAI()
    }

    private func triggerAI() {
        guard status == .playing, position.side != humanColor else { return }
        thinking = true
        message = "Thinking…"
        let pos = position
        let depth = difficulty.depth
        Task.detached(priority: .userInitiated) {
            let move = ChessAI.bestMove(for: pos, depth: depth)
            await MainActor.run {
                self.thinking = false
                if let move {
                    self.apply(move)
                }
            }
        }
    }

    private func updateStatus() {
        if position.isCheckmate {
            let winner = position.side.opposite
            status = .checkmate(winner: winner)
            if winner == humanColor { wins += 1; message = "Checkmate — you win! 🏆" }
            else { losses += 1; message = "Checkmate — the AI wins." }
            persist()
        } else if position.isStalemate {
            status = .stalemate; draws += 1; message = "Stalemate — it's a draw."; persist()
        } else if position.halfmove >= 100 || position.isInsufficientMaterial {
            status = .draw; draws += 1; message = "Draw."; persist()
        } else if position.isInCheck(position.side) {
            message = position.side == humanColor ? "You're in check!" : "AI is in check"
        } else {
            message = position.side == humanColor ? "Your move" : "AI to move"
        }
    }

    private func persist() {
        defaults.set(wins, forKey: "notchly.chess.wins")
        defaults.set(losses, forKey: "notchly.chess.losses")
        defaults.set(draws, forKey: "notchly.chess.draws")
    }
}

// MARK: - View

struct ChessView: View {
    @ObservedObject var game: ChessGame
    private let cell: CGFloat = 52

    var body: some View {
        VStack(spacing: 14) {
            header
            boardView
            footer
        }
        .padding(20)
        .frame(width: 460, height: 640, alignment: .top)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Chess").font(.system(.title2, design: .rounded).weight(.black)).foregroundStyle(.white)
                Text("W \(game.wins) · L \(game.losses) · D \(game.draws)")
                    .font(.system(size: 10, design: .rounded)).foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            HStack(spacing: 6) {
                if game.thinking { ProgressView().controlSize(.small).tint(.white) }
                Text(game.message)
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .foregroundStyle(statusTint)
            }
        }
        .frame(width: cell * 8)
    }

    private var boardView: some View {
        VStack(spacing: 0) {
            ForEach(0..<8, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<8, id: \.self) { col in
                        squareView(rank: 7 - row, file: col)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.15), lineWidth: 1))
        .overlay(alignment: .center) { promotionOverlay }
    }

    private func squareView(rank: Int, file: Int) -> some View {
        let sq = rank * 8 + file
        let isLight = (rank + file) % 2 == 1
        let base = isLight ? Color(red: 0.90, green: 0.87, blue: 0.80) : Color(red: 0.40, green: 0.52, blue: 0.38)
        let isTarget = game.legalTargets.contains(sq)
        let isLast = game.lastMove.map { $0.from == sq || $0.to == sq } ?? false

        return ZStack {
            base
            if isLast { Color.yellow.opacity(0.28) }
            if game.selected == sq { Color.yellow.opacity(0.5) }
            if game.inCheckSquare == sq { Color.red.opacity(0.55) }

            if let piece = game.position.squares[sq] {
                Text(piece.kind.glyph)
                    .font(.system(size: 34))
                    .foregroundStyle(piece.color == .white ? .white : .black)
                    .shadow(color: piece.color == .white ? .black.opacity(0.55) : .white.opacity(0.35), radius: 0.5)
            }
            if isTarget {
                if game.position.squares[sq] == nil {
                    Circle().fill(.black.opacity(0.28)).frame(width: 16, height: 16)
                } else {
                    Circle().strokeBorder(.black.opacity(0.35), lineWidth: 4)
                        .padding(3)
                }
            }
        }
        .frame(width: cell, height: cell)
        .contentShape(Rectangle())
        .onTapGesture { game.tap(sq) }
    }

    @ViewBuilder
    private var promotionOverlay: some View {
        if game.pendingPromotion != nil {
            VStack(spacing: 10) {
                Text("Promote to").font(.system(.headline, design: .rounded).weight(.bold)).foregroundStyle(.white)
                HStack(spacing: 10) {
                    ForEach([PieceKind.queen, .rook, .bishop, .knight], id: \.rawValue) { kind in
                        Button { game.completePromotion(kind) } label: {
                            Text(kind.glyph)
                                .font(.system(size: 34))
                                .foregroundStyle(.white)
                                .frame(width: 52, height: 52)
                                .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.15)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(20)
            .background(RoundedRectangle(cornerRadius: 16).fill(.black.opacity(0.85)))
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Picker("Level", selection: $game.difficulty) {
                ForEach(ChessGame.Difficulty.allCases) { d in Text(d.label).tag(d) }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            .disabled(game.thinking)

            Spacer()

            Button { game.newGame() } label: {
                Label("New game", systemImage: "arrow.clockwise")
                    .font(.system(.callout, design: .rounded).weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Color.blue))
            }
            .buttonStyle(.plain)
        }
        .frame(width: cell * 8)
    }

    private var statusTint: Color {
        switch game.status {
        case .checkmate(let w): return w == game.humanColor ? .green : .red
        case .stalemate, .draw: return .orange
        case .playing: return game.inCheckSquare != nil ? .orange : .white.opacity(0.8)
        }
    }
}

// MARK: - Window presenter

@MainActor
enum ChessWindowPresenter {
    private static var window: NSWindow?
    private static let game = ChessGame()

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = GameWindow.make(title: "Chess", design: CGSize(width: 460, height: 640)) {
            ChessView(game: game)
        }
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

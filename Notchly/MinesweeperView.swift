//
//  MinesweeperView.swift
//  Notchly — Minesweeper UI
//

import SwiftUI
import AppKit

struct MinesweeperView: View {
    @ObservedObject var game: MinesweeperGame
    @State private var flagMode = false

    private let cell: CGFloat = 28
    private let gap: CGFloat = 2

    var body: some View {
        VStack(spacing: 14) {
            header
            board
            controls
        }
        .padding(20)
        .frame(width: 500, height: 640, alignment: .top)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            counter(icon: "flag.fill", value: game.minesRemaining, tint: .red)
            Spacer()
            Text(faceEmoji).font(.system(size: 30))
            Spacer()
            counter(icon: "clock.fill", value: game.elapsed, tint: .cyan)
        }
        .frame(maxWidth: cell * CGFloat(game.cols) + gap * CGFloat(game.cols - 1))
    }

    private func counter(icon: String, value: Int, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(String(format: "%03d", value))
                .font(.system(.title3, design: .monospaced).weight(.bold))
                .foregroundStyle(.white)
        }
    }

    private var faceEmoji: String {
        switch game.status {
        case .won:  return "😎"
        case .lost: return "💥"
        default:    return "🙂"
        }
    }

    // MARK: Board

    private var board: some View {
        VStack(spacing: gap) {
            ForEach(0..<game.rows, id: \.self) { r in
                HStack(spacing: gap) {
                    ForEach(0..<game.cols, id: \.self) { c in
                        cellView(game.cells[r * game.cols + c])
                    }
                }
            }
        }
    }

    private func cellView(_ c: MinesweeperGame.Cell) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(c.revealed ? Color.white.opacity(0.08) : Color.white.opacity(0.22))
                .overlay(
                    RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.12), lineWidth: 1)
                )
            content(for: c)
        }
        .frame(width: cell, height: cell)
        .contentShape(Rectangle())
        .onTapGesture { game.tap(c.id, flagMode: flagMode) }
        .onLongPressGesture(minimumDuration: 0.3) { game.toggleFlag(c.id) }
    }

    @ViewBuilder
    private func content(for c: MinesweeperGame.Cell) -> some View {
        if c.flagged && !c.revealed {
            Text("🚩").font(.system(size: 15))
        } else if c.revealed {
            if c.isMine {
                Text("💣").font(.system(size: 15))
            } else if c.adjacent > 0 {
                Text("\(c.adjacent)")
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(numberColor(c.adjacent))
            }
        }
    }

    private func numberColor(_ n: Int) -> Color {
        switch n {
        case 1: return .blue
        case 2: return .green
        case 3: return .red
        case 4: return .indigo
        case 5: return .orange
        case 6: return .teal
        case 7: return .pink
        default: return .white
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 12) {
            if game.status == .won {
                Text("Cleared in \(game.elapsed)s" + (game.bestTime == game.elapsed ? " — new best! 🏆" : ""))
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .foregroundStyle(.green)
            } else if game.status == .lost {
                Text("Boom! Try again.")
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .foregroundStyle(.red)
            } else if game.bestTime > 0 {
                Text("Best: \(game.bestTime)s")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
            }

            HStack(spacing: 12) {
                Button {
                    flagMode.toggle()
                } label: {
                    Label(flagMode ? "Flag mode: ON" : "Flag mode: OFF", systemImage: "flag.fill")
                        .font(.system(.callout, design: .rounded).weight(.bold))
                        .foregroundStyle(flagMode ? .black : .white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(flagMode ? Color.yellow : Color.white.opacity(0.15)))
                }
                .buttonStyle(.plain)

                Button {
                    game.reset()
                } label: {
                    Label("New game", systemImage: "arrow.clockwise")
                        .font(.system(.callout, design: .rounded).weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(Color.blue))
                }
                .buttonStyle(.plain)
            }

            Picker("Difficulty", selection: $game.difficulty) {
                ForEach(MinesweeperGame.Difficulty.allCases) { d in
                    Text(d.label).tag(d)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)

            Text("Tap to reveal · long-press or Flag mode to flag")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.white.opacity(0.4))
        }
    }
}

// MARK: - Window presenter

@MainActor
enum MinesweeperWindowPresenter {
    private static var window: NSWindow?
    private static let game = MinesweeperGame()

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = GameWindow.make(title: "Minesweeper", design: CGSize(width: 500, height: 640)) {
            MinesweeperView(game: game)
        }
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

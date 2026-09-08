//
//  BreakoutView.swift
//  Notchly — Breakout UI
//
//  Renders the game in a Canvas and drives the paddle from mouse movement via
//  `.onContinuousHover` (pointer-only — no keyboard focus required). Opened in
//  its own window from the panel footer via BreakoutWindowPresenter.
//

import SwiftUI
import AppKit

struct BreakoutView: View {
    @StateObject private var game = BreakoutGame()

    private let fieldW = BreakoutGame.fieldWidth
    private let fieldH = BreakoutGame.fieldHeight

    var body: some View {
        VStack(spacing: 12) {
            scoreBar
            playfield
            Text(game.message)
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(height: 16)
        }
        .padding(18)
        .frame(width: fieldW + 36, height: fieldH + 96)
        .background(
            LinearGradient(colors: [Color(red: 0.05, green: 0.06, blue: 0.12),
                                    Color(red: 0.02, green: 0.02, blue: 0.06)],
                           startPoint: .top, endPoint: .bottom)
        )
        .onAppear { game.startLoop() }
        .onDisappear { game.stopLoop() }
    }

    // MARK: Score bar

    private var scoreBar: some View {
        HStack(spacing: 14) {
            Label("\(game.score)", systemImage: "star.fill")
                .foregroundStyle(.yellow)
            Label("\(game.highScore)", systemImage: "trophy.fill")
                .foregroundStyle(.orange)
            Spacer()
            Text("Lv \(game.level)")
                .foregroundStyle(.white.opacity(0.8))
            HStack(spacing: 3) {
                ForEach(0..<max(0, game.lives), id: \.self) { _ in
                    Image(systemName: "heart.fill").foregroundStyle(.red)
                }
            }
        }
        .font(.system(.subheadline, design: .rounded).weight(.bold))
    }

    // MARK: Playfield

    private var playfield: some View {
        Canvas { ctx, size in
            let sx = size.width / fieldW
            let sy = size.height / fieldH

            // Bricks
            for brick in game.bricks where brick.alive {
                let r = CGRect(x: brick.rect.minX * sx, y: brick.rect.minY * sy,
                               width: brick.rect.width * sx, height: brick.rect.height * sy)
                let path = Path(roundedRect: r, cornerRadius: 3)
                ctx.fill(path, with: .color(BreakoutGame.color(for: brick.colorIndex)))
            }

            // Paddle
            let half = game.paddleWidth / 2
            let paddleRect = CGRect(x: (game.paddleX - half) * sx,
                                    y: (fieldH - 26) * sy,
                                    width: game.paddleWidth * sx,
                                    height: game.paddleHeight * sy)
            ctx.fill(Path(roundedRect: paddleRect, cornerRadius: 6),
                     with: .linearGradient(
                        Gradient(colors: [.white, Color(white: 0.7)]),
                        startPoint: CGPoint(x: paddleRect.midX, y: paddleRect.minY),
                        endPoint: CGPoint(x: paddleRect.midX, y: paddleRect.maxY)))

            // Ball
            let br = game.ballRadius
            let ballRect = CGRect(x: (game.ball.x - br) * sx, y: (game.ball.y - br) * sy,
                                  width: br * 2 * sx, height: br * 2 * sy)
            ctx.fill(Path(ellipseIn: ballRect), with: .color(.white))
        }
        .frame(width: fieldW, height: fieldH)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.12)))
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            if case .active(let location) = phase {
                game.movePaddle(toX: location.x)
            }
        }
        .onTapGesture { game.primaryAction() }
    }
}

// MARK: - Window presenter

@MainActor
enum BreakoutWindowPresenter {
    private static var window: NSWindow?

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0,
                                width: BreakoutGame.fieldWidth + 36,
                                height: BreakoutGame.fieldHeight + 96),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "Notchly Breakout"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: BreakoutView())
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

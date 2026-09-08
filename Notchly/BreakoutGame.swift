//
//  BreakoutGame.swift
//  Notchly — Breakout
//
//  A compact, pointer-only Breakout. The paddle tracks the mouse's x position
//  (no keyboard focus needed — the notch panel/game window never becomes key),
//  so it fits the "mouse-only micro-game" constraint. Bricks, lives, levels,
//  and a persistent high score. Physics run on a fixed-step game-loop timer;
//  the view renders the published state in a Canvas.
//

import Foundation
import Combine
import SwiftUI
import AppKit

@MainActor
final class BreakoutGame: ObservableObject {

    enum Phase { case ready, playing, paused, gameOver, cleared }

    // Logical playfield (points). The view scales its Canvas to this.
    static let fieldWidth: CGFloat = 460
    static let fieldHeight: CGFloat = 320

    struct Brick: Identifiable {
        let id = UUID()
        var rect: CGRect
        var colorIndex: Int
        var alive = true
    }

    // Published game state
    @Published private(set) var ball: CGPoint = .zero
    @Published private(set) var paddleX: CGFloat = fieldWidth / 2      // paddle center x
    @Published private(set) var bricks: [Brick] = []
    @Published private(set) var phase: Phase = .ready
    @Published private(set) var score = 0
    @Published private(set) var lives = 3
    @Published private(set) var level = 1
    @Published private(set) var highScore: Int { didSet { defaults.set(highScore, forKey: K.high) } }
    @Published private(set) var message = "Move the mouse, click to launch"

    // Geometry constants
    let paddleWidth: CGFloat = 92
    let paddleHeight: CGFloat = 12
    let ballRadius: CGFloat = 7
    private var paddleY: CGFloat { Self.fieldHeight - 26 }

    // Physics
    private var velocity: CGVector = .zero
    private var baseSpeed: CGFloat = 300
    private var timer: Timer?
    private let step: CGFloat = 1.0 / 120.0

    private let defaults = UserDefaults.standard
    private enum K { static let high = "notchly.breakout.high" }

    private let brickColors = 5   // number of row colors

    init() {
        highScore = defaults.integer(forKey: K.high)
        resetLevel(buildOnly: true)
        ball = CGPoint(x: Self.fieldWidth / 2, y: paddleY - ballRadius - 1)
    }

    // MARK: - Lifecycle

    func startLoop() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: step, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopLoop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Input

    /// Called from the view as the mouse moves. `x` is in field coordinates.
    func movePaddle(toX x: CGFloat) {
        let half = paddleWidth / 2
        paddleX = min(max(half, x), Self.fieldWidth - half)
        // Carry the ball along with the paddle before launch.
        if phase == .ready {
            ball = CGPoint(x: paddleX, y: paddleY - ballRadius - 1)
        }
    }

    /// Click / tap: launch the ball, resume, or start a new game.
    func primaryAction() {
        switch phase {
        case .ready:
            launch()
        case .paused:
            phase = .playing
            message = ""
        case .gameOver:
            newGame()
        case .cleared:
            resetLevel()          // keep score/lives, build the next level
        case .playing:
            break
        }
    }

    func pause() {
        if phase == .playing { phase = .paused; message = "Paused — click to resume" }
    }

    func newGame() {
        score = 0
        lives = 3
        level = 1
        baseSpeed = 300
        resetLevel()
    }

    // MARK: - Setup

    private func resetLevel(buildOnly: Bool = false) {
        buildBricks()
        phase = .ready
        paddleX = Self.fieldWidth / 2
        ball = CGPoint(x: paddleX, y: paddleY - ballRadius - 1)
        velocity = .zero
        if !buildOnly { message = "Level \(level) — click to launch" }
    }

    private func buildBricks() {
        bricks = []
        let cols = 9, rows = 5
        let topInset: CGFloat = 34
        let sideInset: CGFloat = 14
        let gap: CGFloat = 6
        let usableW = Self.fieldWidth - sideInset * 2 - gap * CGFloat(cols - 1)
        let bw = usableW / CGFloat(cols)
        let bh: CGFloat = 16
        for r in 0..<rows {
            for c in 0..<cols {
                let x = sideInset + CGFloat(c) * (bw + gap)
                let y = topInset + CGFloat(r) * (bh + gap)
                bricks.append(Brick(rect: CGRect(x: x, y: y, width: bw, height: bh),
                                    colorIndex: r % brickColors))
            }
        }
    }

    private func launch() {
        phase = .playing
        message = ""
        // Launch upward at a slight angle, direction based on paddle position.
        let angle = CGFloat.random(in: -0.35...0.35)
        velocity = CGVector(dx: sin(angle) * baseSpeed, dy: -cos(angle) * baseSpeed)
    }

    // MARK: - Game loop

    private func tick() {
        guard phase == .playing else { return }

        // Integrate in two sub-steps to avoid tunnelling at higher speeds.
        for _ in 0..<2 {
            advance(dt: step / 2)
            if phase != .playing { break }
        }
    }

    private func advance(dt: CGFloat) {
        var pos = ball
        pos.x += velocity.dx * dt
        pos.y += velocity.dy * dt

        let r = ballRadius

        // Side walls
        if pos.x - r < 0 { pos.x = r; velocity.dx = abs(velocity.dx) }
        if pos.x + r > Self.fieldWidth { pos.x = Self.fieldWidth - r; velocity.dx = -abs(velocity.dx) }
        // Top wall
        if pos.y - r < 0 { pos.y = r; velocity.dy = abs(velocity.dy) }

        // Bottom → lose a life
        if pos.y - r > Self.fieldHeight {
            loseLife()
            return
        }

        // Paddle
        let halfPaddle = paddleWidth / 2
        if velocity.dy > 0,
           pos.y + r >= paddleY,
           pos.y + r <= paddleY + paddleHeight + 8,
           pos.x >= paddleX - halfPaddle - r,
           pos.x <= paddleX + halfPaddle + r {
            pos.y = paddleY - r
            // Reflect; steer based on where it hit the paddle.
            let offset = (pos.x - paddleX) / halfPaddle          // -1 … 1
            let speed = max(baseSpeed, hypot(velocity.dx, velocity.dy))
            let bounce = offset * 0.9                              // radians-ish steer
            velocity = CGVector(dx: sin(bounce) * speed, dy: -abs(cos(bounce) * speed))
        }

        // Bricks
        if let hit = bricks.firstIndex(where: { $0.alive && $0.rect.insetBy(dx: -r, dy: -r).contains(pos) }) {
            let brick = bricks[hit].rect
            // Decide reflection axis by comparing penetration depths.
            let overlapX = min(pos.x - brick.minX, brick.maxX - pos.x)
            let overlapY = min(pos.y - brick.minY, brick.maxY - pos.y)
            if overlapX < overlapY {
                velocity.dx = -velocity.dx
            } else {
                velocity.dy = -velocity.dy
            }
            bricks[hit].alive = false
            score += 10
            if score > highScore { highScore = score }

            if bricks.allSatisfy({ !$0.alive }) {
                ball = pos
                nextLevel()
                return
            }
        }

        ball = pos
    }

    private func loseLife() {
        lives -= 1
        velocity = .zero
        if lives <= 0 {
            phase = .gameOver
            message = "Game over — click for a new game"
        } else {
            phase = .ready
            paddleX = Self.fieldWidth / 2
            ball = CGPoint(x: paddleX, y: paddleY - ballRadius - 1)
            message = "\(lives) \(lives == 1 ? "life" : "lives") left — click to launch"
        }
    }

    private func nextLevel() {
        level += 1
        baseSpeed = min(520, baseSpeed + 30)   // speed up, capped
        phase = .cleared
        message = "Level \(level - 1) cleared! Click for level \(level)"
        // Rebuild happens on the next primaryAction via newGame? No — resetLevel.
    }

    /// Color for a brick row (used by the view).
    static func color(for index: Int) -> Color {
        switch index {
        case 0: return Color(red: 0.98, green: 0.36, blue: 0.36)
        case 1: return Color(red: 0.98, green: 0.65, blue: 0.30)
        case 2: return Color(red: 0.97, green: 0.85, blue: 0.35)
        case 3: return Color(red: 0.45, green: 0.83, blue: 0.55)
        default: return Color(red: 0.45, green: 0.66, blue: 0.98)
        }
    }
}

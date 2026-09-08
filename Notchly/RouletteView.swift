//
//  RouletteView.swift
//  Notchly — European Roulette UI
//

import SwiftUI
import AppKit

struct RouletteView: View {
    @ObservedObject var game: RouletteGame
    @State private var rotation: Double = 0
    @State private var spinStart = Date()
    @State private var glow = false

    var body: some View {
        VStack(spacing: 10) {
            topBar
            wheel
            resultBar
            numbersBoard
            outsideBets
            controls
        }
        .padding(16)
        .frame(width: 460, height: 770)
        .background(
            LinearGradient(colors: [Color(red: 0.05, green: 0.30, blue: 0.16),
                                    Color(red: 0.02, green: 0.14, blue: 0.09)],
                           startPoint: .top, endPoint: .bottom)
        )
        .onChange(of: game.result) { _, r in
            guard let r, game.phase == .spinning else { return }
            spinTo(r)
        }
    }

    private var topBar: some View {
        HStack {
            Label("\(game.chips)", systemImage: "dollarsign.circle.fill")
                .font(.system(.title3, design: .rounded).weight(.bold)).foregroundStyle(.yellow)
            Spacer()
            Label("\(game.highScore)", systemImage: "trophy.fill")
                .font(.system(.subheadline, design: .rounded).weight(.bold)).foregroundStyle(.orange)
        }
    }

    // MARK: Wheel

    private var wheel: some View {
        ZStack {
            // Neon glow ring that pulses while spinning.
            Circle()
                .strokeBorder(
                    AngularGradient(colors: [.orange, .yellow, .orange, .red, .orange], center: .center),
                    lineWidth: 3)
                .frame(width: 214, height: 214)
                .shadow(color: .orange.opacity(glow ? 0.9 : 0.4), radius: glow ? 22 : 8)

            RouletteWheel(rotation: rotation)
                .frame(width: 210, height: 210)
            // The ball: orbits + spirals into the pocket while spinning,
            // rests in the pocket once stopped.
            RouletteBall(spinning: game.phase == .spinning,
                         settled: game.phase == .result,
                         spinStart: spinStart)
                .frame(width: 210, height: 210)
            // Pointer
            Triangle()
                .fill(LinearGradient(colors: [.white, Color(white: 0.7)], startPoint: .top, endPoint: .bottom))
                .frame(width: 16, height: 14)
                .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                .offset(y: -110)
        }
        .frame(height: 224)
        .onChange(of: game.phase) { _, p in
            if p == .spinning {
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) { glow = true }
            } else {
                withAnimation(.easeInOut(duration: 0.3)) { glow = false }
            }
        }
    }

    private func spinTo(_ r: Int) {
        let seg = 360.0 / 37
        guard let index = RouletteGame.wheelOrder.firstIndex(of: r) else { return }
        let targetAngle = -(Double(index) * seg + seg / 2)
        let current = rotation.truncatingRemainder(dividingBy: 360)
        let delta = targetAngle - current
        spinStart = Date()
        withAnimation(.easeOut(duration: 3.4)) {
            rotation += 360 * 5 + delta
        }
    }

    // MARK: Result

    private var resultBar: some View {
        VStack(spacing: 2) {
            if let r = game.result, game.phase == .result {
                Text("\(r)")
                    .font(.system(size: 22, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(swiftColor(r)))
                    .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 2))
                    .shadow(color: swiftColor(r).opacity(0.9), radius: 12)
                    .transition(.scale.combined(with: .opacity))
            }
            Text(game.message)
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .foregroundStyle(game.lastNet > 0 && game.phase == .result ? .green : .white.opacity(0.85))
        }
        .frame(height: 64)
    }

    // MARK: Numbers board

    private var numbersBoard: some View {
        VStack(spacing: 3) {
            numberCell(0)
                .frame(maxWidth: .infinity)
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 3) {
                    ForEach(1...12, id: \.self) { col in
                        numberCell((row * 12) + col)
                    }
                }
            }
        }
    }

    private func numberCell(_ n: Int) -> some View {
        Button { game.place(.straight(n)) } label: {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 4).fill(swiftColor(n))
                Text("\(n)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let amt = game.bets[.straight(n)] {
                    Text("\(amt)")
                        .font(.system(size: 7, weight: .black, design: .rounded))
                        .foregroundStyle(.black)
                        .padding(2)
                        .background(Circle().fill(.yellow))
                        .offset(x: 2, y: -2)
                }
            }
            .frame(height: 26)
        }
        .buttonStyle(.plain)
    }

    // MARK: Outside bets

    private var outsideBets: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                outsideButton("1st 12", .dozen(1))
                outsideButton("2nd 12", .dozen(2))
                outsideButton("3rd 12", .dozen(3))
            }
            HStack(spacing: 4) {
                outsideButton("1-18", .low)
                outsideButton("EVEN", .even)
                outsideButton("RED", .red, fill: Color(red: 0.7, green: 0.12, blue: 0.12))
                outsideButton("BLACK", .black, fill: Color(white: 0.12))
                outsideButton("ODD", .odd)
                outsideButton("19-36", .high)
            }
        }
    }

    private func outsideButton(_ label: String, _ bet: RouletteBet, fill: Color = Color.white.opacity(0.12)) -> some View {
        Button { game.place(bet) } label: {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 5).fill(fill)
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(.yellow, lineWidth: game.bets[bet] != nil ? 2 : 0))
                Text(label)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let amt = game.bets[bet] {
                    Text("\(amt)").font(.system(size: 7, weight: .black, design: .rounded))
                        .foregroundStyle(.black).padding(2)
                        .background(Circle().fill(.yellow)).offset(x: 2, y: -2)
                }
            }
            .frame(height: 26)
        }
        .buttonStyle(.plain)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("Chip").font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
                ForEach([5, 25, 100], id: \.self) { v in
                    Button { game.setChipSize(v) } label: {
                        Text("\(v)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(game.chipSize == v ? .black : .white)
                            .frame(width: 38, height: 26)
                            .background(Capsule().fill(game.chipSize == v ? Color.yellow : .white.opacity(0.15)))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Text("Bet \(game.totalBet)")
                    .font(.system(.caption, design: .rounded).weight(.bold))
                    .foregroundStyle(.yellow)
            }
            HStack(spacing: 10) {
                Button { game.clearBets() } label: {
                    Text("Clear").font(.system(.subheadline, design: .rounded).weight(.bold))
                        .foregroundStyle(.white).frame(maxWidth: .infinity).padding(.vertical, 9)
                        .background(Capsule().fill(.white.opacity(0.18)))
                }.buttonStyle(.plain)
                Button { Task { await game.spin() } } label: {
                    Text(game.phase == .spinning ? "Spinning…" : "SPIN")
                        .font(.system(.subheadline, design: .rounded).weight(.black))
                        .foregroundStyle(.white).frame(maxWidth: .infinity).padding(.vertical, 9)
                        .background(Capsule().fill(game.totalBet > 0 && game.phase != .spinning ? Color.green : .gray))
                }
                .buttonStyle(.plain)
                .disabled(game.totalBet == 0 || game.phase == .spinning)
            }
        }
    }

    private func swiftColor(_ n: Int) -> Color {
        switch RouletteGame.color(n) {
        case .green: return Color(red: 0.1, green: 0.5, blue: 0.25)
        case .red:   return Color(red: 0.7, green: 0.12, blue: 0.12)
        case .black: return Color(white: 0.12)
        }
    }
}

// MARK: - Wheel drawing

struct RouletteWheel: View {
    let rotation: Double

    private let gold = Gradient(colors: [
        Color(red: 1.0, green: 0.88, blue: 0.45), Color(red: 0.82, green: 0.62, blue: 0.22),
        Color(red: 0.5, green: 0.34, blue: 0.10)
    ])
    private let metal = Gradient(colors: [
        Color(white: 0.92), Color(white: 0.55), Color(white: 0.22)
    ])

    var body: some View {
        Canvas { ctx, size in
            let R = min(size.width, size.height) / 2 - 4
            let c = CGPoint(x: size.width / 2, y: size.height / 2)

            // Outer gold rim with a drop shadow.
            ctx.drawLayer { l in
                l.addFilter(.shadow(color: .black.opacity(0.6), radius: 10, y: 5))
                l.fill(circle(c, R), with: .radialGradient(gold, center: c, startRadius: R * 0.55, endRadius: R))
            }
            // Dark separator + glossy ball track.
            ctx.fill(circle(c, R * 0.9), with: .color(Color(white: 0.04)))
            ctx.fill(circle(c, R * 0.87),
                     with: .radialGradient(Gradient(colors: [Color(white: 0.26), Color(white: 0.07)]),
                                           center: c, startRadius: R * 0.55, endRadius: R * 0.87))

            // Pocket ring.
            let seg = 2 * Double.pi / 37
            let outerR = R * 0.84, innerR = R * 0.5
            for (i, num) in RouletteGame.wheelOrder.enumerated() {
                let start = Double(i) * seg - .pi / 2
                let end = start + seg
                var p = Path()
                p.addArc(center: c, radius: outerR, startAngle: .radians(start), endAngle: .radians(end), clockwise: false)
                p.addLine(to: point(c, innerR, end))
                p.addArc(center: c, radius: innerR, startAngle: .radians(end), endAngle: .radians(start), clockwise: true)
                p.closeSubpath()
                ctx.fill(p, with: .color(wedgeColor(num)))

                // Gold fret between pockets.
                var fret = Path()
                fret.move(to: point(c, innerR, start)); fret.addLine(to: point(c, outerR, start))
                ctx.stroke(fret, with: .linearGradient(gold, startPoint: point(c, innerR, start), endPoint: point(c, outerR, start)), lineWidth: 1)

                // Number, rotated to sit radially.
                let mid = start + seg / 2
                let pos = point(c, (innerR + outerR) / 2, mid)
                ctx.drawLayer { l in
                    l.translateBy(x: pos.x, y: pos.y)
                    l.rotate(by: .radians(mid + .pi / 2))
                    l.draw(Text("\(num)").font(.system(size: 9, weight: .heavy, design: .rounded)).foregroundColor(.white),
                           at: .zero)
                }
            }

            // Metallic hub + center turret.
            ctx.fill(circle(c, innerR),
                     with: .radialGradient(metal, center: CGPoint(x: c.x - innerR * 0.3, y: c.y - innerR * 0.3),
                                           startRadius: 0, endRadius: innerR))
            ctx.stroke(circle(c, innerR), with: .color(Color(white: 0.1)), lineWidth: 1.5)
            // Cross spinner.
            for k in 0..<4 {
                let a = Double(k) * .pi / 2
                var arm = Path()
                arm.move(to: c); arm.addLine(to: point(c, innerR * 0.8, a))
                ctx.stroke(arm, with: .linearGradient(gold, startPoint: c, endPoint: point(c, innerR * 0.8, a)), lineWidth: 4)
            }
            ctx.fill(circle(c, innerR * 0.18), with: .radialGradient(gold, center: c, startRadius: 0, endRadius: innerR * 0.18))
        }
        .rotationEffect(.degrees(rotation))
    }

    private func circle(_ c: CGPoint, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    }
    private func point(_ c: CGPoint, _ r: CGFloat, _ a: Double) -> CGPoint {
        CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
    }
    private func wedgeColor(_ n: Int) -> Color {
        switch RouletteGame.color(n) {
        case .green: return Color(red: 0.08, green: 0.55, blue: 0.30)
        case .red:   return Color(red: 0.78, green: 0.10, blue: 0.10)
        case .black: return Color(white: 0.09)
        }
    }
}

// MARK: - The ball

struct RouletteBall: View {
    let spinning: Bool
    let settled: Bool
    let spinStart: Date
    private let duration = 3.4

    var body: some View {
        if spinning {
            TimelineView(.animation) { timeline in
                Canvas { ctx, size in
                    let t = timeline.date.timeIntervalSince(spinStart)
                    draw(ctx, size, progress: min(1, max(0, t / duration)))
                }
            }
        } else if settled {
            Canvas { ctx, size in draw(ctx, size, progress: 1) }
        } else {
            Color.clear
        }
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, progress: Double) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let wheelR = min(size.width, size.height) / 2
        let ease = 1 - pow(1 - progress, 2)          // ease-out deceleration

        // Orbit: many fast revolutions early, converging to the top pocket.
        let top = -Double.pi / 2
        let revolutions = 7.0
        let theta = top - (1 - ease) * revolutions * 2 * .pi

        // Roll on the outer track, then drop into the pocket ring, with a
        // fading bounce so it rattles before settling.
        let outer = wheelR * 0.86
        let settle = wheelR * 0.67
        var radius = outer + (settle - outer) * ease
        radius += abs(sin(progress * .pi * 11)) * (1 - progress) * wheelR * 0.05   // bounce

        let bx = c.x + radius * cos(theta)
        let by = c.y + radius * sin(theta)
        let ballR = wheelR * 0.058
        let rect = CGRect(x: bx - ballR, y: by - ballR, width: ballR * 2, height: ballR * 2)

        // Shadow, body (glossy), highlight.
        ctx.fill(Path(ellipseIn: rect.offsetBy(dx: 1, dy: 2)), with: .color(.black.opacity(0.45)))
        ctx.fill(Path(ellipseIn: rect),
                 with: .radialGradient(Gradient(colors: [.white, Color(white: 0.7)]),
                                       center: CGPoint(x: bx - ballR * 0.3, y: by - ballR * 0.3),
                                       startRadius: 0, endRadius: ballR * 1.3))
        ctx.fill(Path(ellipseIn: CGRect(x: bx - ballR * 0.35, y: by - ballR * 0.45,
                                        width: ballR * 0.5, height: ballR * 0.5)),
                 with: .color(.white))
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Window presenter

@MainActor
enum RouletteWindowPresenter {
    private static var window: NSWindow?
    private static let game = RouletteGame()

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 770),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Roulette"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: RouletteView(game: game))
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

//
//  SportsView.swift
//  Notchly — Live Sports Tracker UI
//
//  Expanded-panel sports section (Live / Yesterday tabs) + a compact live-score
//  ticker for the collapsed notch.
//

import SwiftUI
import AppKit
import Combine

// MARK: - Expanded section

struct SportsView: View {
    @ObservedObject var sports: SportsManager
    @State private var tab: Tab = .live

    enum Tab { case live, yesterday }

    private var liveOrUpcoming: [LiveGame] {
        // Live first, then upcoming; finals drop off the live tab.
        sports.liveGames.filter { $0.state != .final }
            .sorted { lhs, rhs in (lhs.state == .live ? 0 : 1) < (rhs.state == .live ? 0 : 1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            if tab == .live {
                liveList
            } else {
                yesterdayList
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Header + tabs

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sportscourt")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Text("Sports")
                    .font(.system(.caption2, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
            }

            Spacer(minLength: 8)

            tabPill("Live", isOn: tab == .live) { tab = .live }
            tabPill("Yesterday", isOn: tab == .yesterday) { tab = .yesterday }

            // Settings access (gear) — opens the Notchly settings window.
            Button {
                SettingsWindowPresenter.show(sports: sports)
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
    }

    private func tabPill(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(isOn ? .black : .white.opacity(0.7))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(isOn ? Color.white : Color.white.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: Live list

    @ViewBuilder
    private var liveList: some View {
        if liveOrUpcoming.isEmpty {
            emptyText("No live games right now")
        } else {
            VStack(spacing: 4) {
                ForEach(liveOrUpcoming) { game in
                    Button { open(game.link) } label: { liveRow(game) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private func liveRow(_ game: LiveGame) -> some View {
        let isPre = game.state == .pre
        return HStack(spacing: 6) {
            if game.state == .live {
                PulsingDot()
            } else {
                Circle().fill(.clear).frame(width: 6, height: 6)
            }

            Text(game.homeAbbr)
                .frame(width: 34, alignment: .leading)

            Text(scoreString(game))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(isPre ? .white.opacity(0.4) : .white)

            Text(game.awayAbbr)
                .frame(width: 34, alignment: .leading)

            Spacer(minLength: 4)

            Text(game.statusDetail)
                .font(.system(size: 9, design: .rounded))
                .foregroundStyle(isPre ? .white.opacity(0.4) : .white.opacity(0.6))
                .lineLimit(1)
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .foregroundStyle(isPre ? .white.opacity(0.4) : .white)
        .contentShape(Rectangle())
    }

    private func scoreString(_ game: LiveGame) -> String {
        if game.state == .pre { return "—" }
        let h = game.homeScore.map(String.init) ?? "0"
        let a = game.awayScore.map(String.init) ?? "0"
        return "\(h)–\(a)"
    }

    // MARK: Yesterday list

    @ViewBuilder
    private var yesterdayList: some View {
        if sports.yesterdayResults.isEmpty {
            emptyText("No games yesterday")
        } else {
            VStack(spacing: 4) {
                ForEach(sports.yesterdayResults) { game in
                    Button { open(game.link) } label: { resultRow(game) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private func resultRow(_ game: FinishedGame) -> some View {
        HStack(spacing: 6) {
            Text(game.homeTeam)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(game.homeScore)–\(game.awayScore)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))

            Text(game.awayTeam)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)

            Text(game.league.badge)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(.white.opacity(0.12)))
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .foregroundStyle(.white)
        .contentShape(Rectangle())
    }

    // MARK: Helpers

    private func emptyText(_ s: String) -> some View {
        Text(s)
            .font(.system(.caption2, design: .rounded))
            .foregroundStyle(.white.opacity(0.35))
    }

    private func open(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Pulsing live dot

struct PulsingDot: View {
    @State private var on = false
    var body: some View {
        Circle()
            .fill(Color.green)
            .frame(width: 6, height: 6)
            .opacity(on ? 1 : 0.3)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    on = true
                }
            }
    }
}

// MARK: - Collapsed notch ticker

struct SportsTicker: View {
    @ObservedObject var sports: SportsManager
    @State private var index = 0

    private let cycle = Timer.publish(every: 4, on: .main, in: .common).autoconnect()

    private var live: [LiveGame] { sports.liveGames.filter { $0.state == .live } }

    var body: some View {
        Group {
            if !live.isEmpty {
                let game = live[min(index, live.count - 1)]
                Text(compact(game))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .id(game.id)                                  // crossfade between games
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.4), value: live.first?.id)
        .onReceive(cycle) { _ in
            guard live.count > 1 else { index = 0; return }
            withAnimation(.easeInOut(duration: 0.4)) {
                index = (index + 1) % live.count
            }
        }
    }

    private func compact(_ g: LiveGame) -> String {
        let h = g.homeScore.map(String.init) ?? "0"
        let a = g.awayScore.map(String.init) ?? "0"
        return "\(g.homeAbbr) \(h)–\(a) \(g.awayAbbr)"
    }
}

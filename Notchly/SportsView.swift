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

    /// Games grouped by league, in a stable league order.
    private var groupedLive: [(league: League, games: [LiveGame])] {
        League.allCases.compactMap { league in
            let games = liveOrUpcoming.filter { $0.league == league }
            return games.isEmpty ? nil : (league, games)
        }
    }

    @ViewBuilder
    private var liveList: some View {
        if liveOrUpcoming.isEmpty {
            emptyText("No live games right now")
        } else if liveOrUpcoming.count <= 5 {
            groupedLiveContent
        } else {
            // More than 5 — cap the height and scroll for the rest.
            ScrollView(.vertical, showsIndicators: true) {
                groupedLiveContent
            }
            .frame(height: 132)
        }
    }

    @ViewBuilder
    private var groupedLiveContent: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(groupedLive, id: \.league) { group in
                leagueHeader(group.league)
                ForEach(group.games) { game in
                    Button { open(game.link) } label: { liveRow(game) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private func leagueHeader(_ league: League) -> some View {
        Text(league.displayName.uppercased())
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.45))
            .padding(.top, 3)
    }

    private func liveRow(_ game: LiveGame) -> some View {
        let isPre = game.state == .pre
        let isLive = game.state == .live
        return HStack(spacing: 6) {
            if isLive {
                PulsingDot()
            } else {
                Circle().fill(.clear).frame(width: 6, height: 6)
            }

            // Home: logo + abbreviation
            TeamBadge(logo: game.homeLogo, colorHex: game.homeColor)
            Text(game.homeAbbr)
                .frame(width: 34, alignment: .leading)

            // Scoreboard (live/final) or a dash for upcoming
            Text(scoreString(game))
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(isPre ? .white.opacity(0.4) : .white)

            // Away: abbreviation + logo
            Text(game.awayAbbr)
                .frame(width: 34, alignment: .trailing)
            TeamBadge(logo: game.awayLogo, colorHex: game.awayColor)

            Spacer(minLength: 4)

            // Live → elapsed clock (green); upcoming → kickoff/tip-off time.
            Text(game.statusDetail)
                .font(.system(size: 9, weight: isLive ? .semibold : .regular, design: .rounded))
                .foregroundStyle(isLive ? Color.green
                                 : isPre ? .white.opacity(0.45) : .white.opacity(0.6))
                .lineLimit(1)
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .foregroundStyle(isPre ? .white.opacity(0.5) : .white)
        .contentShape(Rectangle())
    }

    private func scoreString(_ game: LiveGame) -> String {
        if game.state == .pre { return "vs" }
        let h = game.homeScore.map(String.init) ?? "0"
        let a = game.awayScore.map(String.init) ?? "0"
        return "\(h)–\(a)"
    }

    // MARK: Yesterday list

    private var groupedYesterday: [(league: League, games: [FinishedGame])] {
        League.allCases.compactMap { league in
            let games = sports.yesterdayResults.filter { $0.league == league }
            return games.isEmpty ? nil : (league, games)
        }
    }

    @ViewBuilder
    private var yesterdayList: some View {
        if sports.yesterdayResults.isEmpty {
            emptyText("No games yesterday")
        } else if sports.yesterdayResults.count <= 5 {
            groupedYesterdayContent
        } else {
            ScrollView(.vertical, showsIndicators: true) {
                groupedYesterdayContent
            }
            .frame(height: 132)
        }
    }

    @ViewBuilder
    private var groupedYesterdayContent: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(groupedYesterday, id: \.league) { group in
                leagueHeader(group.league)
                ForEach(group.games) { game in
                    Button { open(game.link) } label: { resultRow(game) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private func resultRow(_ game: FinishedGame) -> some View {
        HStack(spacing: 6) {
            TeamBadge(logo: game.homeLogo, colorHex: game.homeColor)
            Text(game.homeTeam)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(game.homeScore)–\(game.awayScore)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))

            Text(game.awayTeam)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
            TeamBadge(logo: game.awayLogo, colorHex: game.awayColor)
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

// MARK: - Team badge (logo, falling back to team-colour dot)

struct TeamBadge: View {
    let logo: URL?
    let colorHex: String?

    var body: some View {
        Group {
            if let logo {
                AsyncImage(url: logo) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                    } else {
                        colorDot
                    }
                }
            } else {
                colorDot
            }
        }
        .frame(width: 16, height: 16)
    }

    private var colorDot: some View {
        Circle()
            .fill(Color(teamHex: colorHex) ?? Color.white.opacity(0.4))
            .frame(width: 11, height: 11)
    }
}

extension Color {
    /// Init from an ESPN team colour hex string ("552583", optionally "#552583").
    init?(teamHex hex: String?) {
        guard var s = hex?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        s = s.replacingOccurrences(of: "#", with: "")
        guard s.count == 6, let value = UInt64(s, radix: 16) else { return nil }
        self = Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
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

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

    /// Show at most three games before scrolling, in both the live and the
    /// yesterday list. Sports sits at the top of the panel, so an uncapped list
    /// pushed the calendar, timer and clipboard off the bottom.
    static let maxVisibleGames = 3
    /// Three rows plus a league header, which is what three games occupy.
    static let scrollHeight: CGFloat = 92

    @ObservedObject var sports: SportsManager
    /// Owned by the caller, which draws the Live / Yesterday pills in its own
    /// header row so an empty scores section costs one line, not three.
    @Binding var tab: Tab

    enum Tab { case live, yesterday }

    private var liveOrUpcoming: [LiveGame] {
        // Live first, then upcoming; finals drop off the live tab.
        sports.liveGames.filter { $0.state != .final }
            .sorted { lhs, rhs in (lhs.state == .live ? 0 : 1) < (rhs.state == .live ? 0 : 1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if tab == .live {
                liveList
            } else {
                yesterdayList
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Header + tabs

    /// Tabs only. The section title and the live count live in the collapsible
    /// "Scores" header that wraps this view, so repeating them here would just
    /// be two headings stacked on top of each other.
    private var header: some View {
        HStack(spacing: 6) {
            tabPill("Live", isOn: tab == .live) { tab = .live }
            tabPill("Yesterday", isOn: tab == .yesterday) { tab = .yesterday }
            Spacer(minLength: 0)
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
            EmptyView()
        } else if liveOrUpcoming.count <= Self.maxVisibleGames {
            groupedLiveContent
        } else {
            // Past three games, cap the height and scroll — the sports block was
            // pushing everything else out of the panel on a busy night.
            ScrollView(.vertical, showsIndicators: true) {
                groupedLiveContent
            }
            .frame(height: Self.scrollHeight)
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

    /// Each league in its own colour, so a mixed list separates at a glance
    /// instead of being a run of identical grey labels.
    private static func leagueTint(_ league: League) -> Color {
        switch league {
        case .nba:              return Color(red: 0.96, green: 0.45, blue: 0.22)  // court orange
        case .euroLeague:       return Color(red: 1.00, green: 0.68, blue: 0.20)
        case .premierLeague:    return Color(red: 0.74, green: 0.30, blue: 0.95)  // EPL purple
        case .championsLeague:  return Color(red: 0.36, green: 0.62, blue: 1.00)
        case .laLiga:           return Color(red: 1.00, green: 0.38, blue: 0.42)
        case .greekSuperLeague: return Color(red: 0.32, green: 0.76, blue: 1.00)
        case .worldCup:         return Color(red: 0.36, green: 0.84, blue: 0.56)
        }
    }

    private func leagueHeader(_ league: League) -> some View {
        let tint = Self.leagueTint(league)
        return HStack(spacing: 5) {
            Capsule()
                .fill(tint)
                .frame(width: 2.5, height: 9)
            Text(league.displayName.uppercased())
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(tint.opacity(0.95))
                .kerning(0.4)
        }
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
        } else if sports.yesterdayResults.count <= Self.maxVisibleGames {
            groupedYesterdayContent
        } else {
            ScrollView(.vertical, showsIndicators: true) {
                groupedYesterdayContent
            }
            .frame(height: Self.scrollHeight)
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
                // One line, always: the flank is only 66pt wide, so a
                // monospaced "LAL 102–98 BOS" wrapped onto two rows. Rounded
                // digits are narrower, and it scales down rather than wrap.
                Text(compact(game))
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .allowsTightening(true)
                    .id(game.id)                                  // crossfade between games
                    .transition(.move(edge: .leading).combined(with: .opacity))
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
        return "\(g.homeAbbr) \(h)-\(a) \(g.awayAbbr)"
    }
}

//
//  SportsManager.swift
//  Notchly — Live Sports Tracker
//
//  Polls ESPN's unofficial public JSON API (no key required, HTTPS, zero config).
//  Live games poll every 45s; otherwise every 5 min. Only games involving
//  followed teams are surfaced (if no teams are followed, all games show so it
//  isn't blank out of the box). All decoding is best-effort (try?) and never
//  crashes on an unexpected shape.
//

import Foundation
import Combine

// MARK: - Public models

enum League: String, CaseIterable, Identifiable, Codable {
    case nba
    case premierLeague
    case championsLeague
    case laLiga
    case worldCup

    var id: String { rawValue }

    /// ESPN path segment after `.../sports/`.
    var path: String {
        switch self {
        case .nba:             return "basketball/nba"
        case .premierLeague:   return "soccer/eng.1"
        case .championsLeague: return "soccer/uefa.champions"
        case .laLiga:          return "soccer/esp.1"
        case .worldCup:        return "soccer/fifa.world"
        }
    }

    var displayName: String {
        switch self {
        case .nba:             return "NBA"
        case .premierLeague:   return "Premier League"
        case .championsLeague: return "Champions League"
        case .laLiga:          return "La Liga"
        case .worldCup:        return "World Cup"
        }
    }

    /// Short badge initial shown on result rows.
    var badge: String {
        switch self {
        case .nba:             return "NBA"
        case .premierLeague:   return "PL"
        case .championsLeague: return "CL"
        case .laLiga:          return "LL"
        case .worldCup:        return "WC"
        }
    }
}

enum GameState {
    case pre, live, final
}

struct LiveGame: Identifiable {
    let id: String
    let homeTeam: String
    let awayTeam: String
    let homeAbbr: String
    let awayAbbr: String
    let homeScore: Int?
    let awayScore: Int?
    let state: GameState
    let statusDetail: String      // clock/minute, "Today 8:30 PM", or "Final"
    let league: League
    let link: URL?
}

struct FinishedGame: Identifiable {
    let id: String
    let homeTeam: String
    let awayTeam: String
    let homeScore: Int
    let awayScore: Int
    let league: League
    let link: URL?
}

// MARK: - Manager

@MainActor
final class SportsManager: ObservableObject {

    @Published private(set) var liveGames: [LiveGame] = []
    @Published private(set) var yesterdayResults: [FinishedGame] = []
    @Published private(set) var isPolling: Bool = false
    @Published private(set) var lastUpdated: Date?

    @Published var followedTeams: [String] {
        didSet { defaults.set(followedTeams, forKey: Keys.followedTeams) }
    }
    @Published var enabledLeagues: Set<League> {
        didSet {
            defaults.set(enabledLeagues.map(\.rawValue), forKey: Keys.enabledLeagues)
        }
    }

    private let baseURL = "https://site.api.espn.com/apis/site/v2/sports/"
    private let defaults = UserDefaults.standard
    private enum Keys {
        static let followedTeams = "notchly.followedTeams"
        static let enabledLeagues = "notchly.enabledLeagues"
    }

    private var pollTask: Task<Void, Never>?

    init() {
        followedTeams = defaults.stringArray(forKey: Keys.followedTeams) ?? []
        if let raw = defaults.array(forKey: Keys.enabledLeagues) as? [String], !raw.isEmpty {
            enabledLeagues = Set(raw.compactMap(League.init(rawValue:)))
        } else {
            enabledLeagues = Set(League.allCases)   // all on by default
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { await pollLoop() }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            await refresh()
            let anyLive = liveGames.contains { $0.state == .live }
            let seconds: UInt64 = anyLive ? 45 : 300
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
        }
    }

    /// One full refresh cycle (live + yesterday).
    func refresh() async {
        isPolling = true
        defer { isPolling = false }
        await fetchLive()
        await fetchYesterday()
    }

    // MARK: - Settings helpers

    func isEnabled(_ league: League) -> Bool { enabledLeagues.contains(league) }

    func setEnabled(_ league: League, _ on: Bool) {
        if on { enabledLeagues.insert(league) } else { enabledLeagues.remove(league) }
    }

    func addTeam(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !followedTeams.contains(trimmed) else { return }
        followedTeams.append(trimmed)
    }

    func removeTeam(at index: Int) {
        guard followedTeams.indices.contains(index) else { return }
        followedTeams.remove(at: index)
    }

    /// Immediate fetch for the Settings "Test fetch" button.
    func testFetch() async -> String {
        await refresh()
        return "Live: \(liveGames.count) · Yesterday: \(yesterdayResults.count)"
    }

    // MARK: - Fetch (live / today)

    private func fetchLive() async {
        var games: [LiveGame] = []
        var anySuccess = false

        for league in League.allCases where enabledLeagues.contains(league) {
            if let events = await fetchScoreboard(path: league.path, date: nil) {
                anySuccess = true
                games += events.compactMap { liveGame(from: $0, league: league) }
            }
        }

        // On total network failure, keep the last cached result.
        guard anySuccess else { return }
        liveGames = filterFollowed(games, home: \.homeTeam, away: \.awayTeam,
                                   homeAbbr: \.homeAbbr, awayAbbr: \.awayAbbr)
        lastUpdated = Date()
    }

    // MARK: - Fetch (yesterday)

    private func fetchYesterday() async {
        guard let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) else { return }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd"
        fmt.timeZone = .current
        let dateString = fmt.string(from: yesterday)

        var results: [FinishedGame] = []
        var anySuccess = false

        for league in League.allCases where enabledLeagues.contains(league) {
            if let events = await fetchScoreboard(path: league.path, date: dateString) {
                anySuccess = true
                results += events.compactMap { finishedGame(from: $0, league: league) }
            }
        }

        guard anySuccess else { return }
        yesterdayResults = filterFollowed(results, home: \.homeTeam, away: \.awayTeam,
                                          homeAbbr: { _ in "" }, awayAbbr: { _ in "" })
    }

    // MARK: - Networking

    /// Returns events on success (possibly empty), or nil on network failure.
    private func fetchScoreboard(path: String, date: String?) async -> [ESPNEvent]? {
        var urlString = baseURL + path + "/scoreboard"
        if let date { urlString += "?dates=\(date)" }
        guard let url = URL(string: urlString) else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let board = try? JSONDecoder().decode(ESPNScoreboard.self, from: data)
            return board?.events ?? []     // decode failure → treat as "no games"
        } catch {
            return nil                      // genuine network failure → keep cache
        }
    }

    // MARK: - Mapping

    private func liveGame(from event: ESPNEvent, league: League) -> LiveGame? {
        guard let comp = event.competitions?.first,
              let competitors = comp.competitors,
              let home = competitors.first(where: { $0.homeAway == "home" }),
              let away = competitors.first(where: { $0.homeAway == "away" }),
              let homeName = home.team?.displayName ?? home.team?.shortDisplayName,
              let awayName = away.team?.displayName ?? away.team?.shortDisplayName
        else { return nil }

        let state = Self.mapState(event.status?.type?.state)
        return LiveGame(
            id: event.id ?? UUID().uuidString,
            homeTeam: homeName,
            awayTeam: awayName,
            homeAbbr: home.team?.abbreviation ?? abbreviate(homeName),
            awayAbbr: away.team?.abbreviation ?? abbreviate(awayName),
            homeScore: Int(home.score ?? ""),
            awayScore: Int(away.score ?? ""),
            state: state,
            statusDetail: statusDetail(for: event, state: state),
            league: league,
            link: firstLink(event)
        )
    }

    private func finishedGame(from event: ESPNEvent, league: League) -> FinishedGame? {
        guard Self.mapState(event.status?.type?.state) == .final,
              let comp = event.competitions?.first,
              let competitors = comp.competitors,
              let home = competitors.first(where: { $0.homeAway == "home" }),
              let away = competitors.first(where: { $0.homeAway == "away" }),
              let homeName = home.team?.displayName ?? home.team?.shortDisplayName,
              let awayName = away.team?.displayName ?? away.team?.shortDisplayName,
              let homeScore = Int(home.score ?? ""),
              let awayScore = Int(away.score ?? "")
        else { return nil }

        return FinishedGame(
            id: event.id ?? UUID().uuidString,
            homeTeam: homeName,
            awayTeam: awayName,
            homeScore: homeScore,
            awayScore: awayScore,
            league: league,
            link: firstLink(event)
        )
    }

    private static func mapState(_ raw: String?) -> GameState {
        switch raw {
        case "in":   return .live
        case "post": return .final
        default:     return .pre
        }
    }

    private func statusDetail(for event: ESPNEvent, state: GameState) -> String {
        switch state {
        case .pre:
            if let date = Self.parseDate(event.date) {
                let f = DateFormatter()
                f.dateFormat = "h:mm a"
                f.timeZone = .current
                return "Today \(f.string(from: date))"
            }
            return "Today"
        case .live:
            return event.status?.type?.shortDetail
                ?? event.status?.displayClock
                ?? "LIVE"
        case .final:
            return "Final"
        }
    }

    private static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: string) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: string)
    }

    private func firstLink(_ event: ESPNEvent) -> URL? {
        event.links?.compactMap { $0.href }.first.flatMap { URL(string: $0) }
    }

    private func abbreviate(_ name: String) -> String {
        String(name.prefix(3)).uppercased()
    }

    // MARK: - Following filter

    private func filterFollowed<T>(
        _ games: [T],
        home: (T) -> String,
        away: (T) -> String,
        homeAbbr: (T) -> String,
        awayAbbr: (T) -> String
    ) -> [T] {
        guard !followedTeams.isEmpty else { return games }   // none followed → show all
        let needles = followedTeams.map { $0.lowercased() }
        return games.filter { game in
            let haystacks = [home(game), away(game), homeAbbr(game), awayAbbr(game)]
                .map { $0.lowercased() }
            return needles.contains { needle in
                haystacks.contains { $0.contains(needle) }
            }
        }
    }
}

// MARK: - ESPN response (best-effort decoding)

private struct ESPNScoreboard: Decodable {
    let events: [ESPNEvent]?
}

struct ESPNEvent: Decodable {
    let id: String?
    let date: String?
    let status: ESPNStatus?
    let competitions: [ESPNCompetition]?
    let links: [ESPNLink]?
}

struct ESPNStatus: Decodable {
    let displayClock: String?
    let period: Int?
    let type: ESPNStatusType?
}

struct ESPNStatusType: Decodable {
    let state: String?
    let completed: Bool?
    let shortDetail: String?
    let detail: String?
}

struct ESPNCompetition: Decodable {
    let competitors: [ESPNCompetitor]?
}

struct ESPNCompetitor: Decodable {
    let homeAway: String?
    let score: String?
    let team: ESPNTeam?
}

struct ESPNTeam: Decodable {
    let displayName: String?
    let shortDisplayName: String?
    let abbreviation: String?
}

struct ESPNLink: Decodable {
    let href: String?
    let rel: [String]?
}

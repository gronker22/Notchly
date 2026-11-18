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
import os

let sportsLog = Logger(subsystem: "com.notchly.Notchly", category: "sports")

// MARK: - Public models

enum League: String, CaseIterable, Identifiable, Codable {
    case nba
    case euroLeague
    case premierLeague
    case championsLeague
    case laLiga
    case greekSuperLeague
    case worldCup

    var id: String { rawValue }

    /// ESPN path segment after `.../sports/`.
    var path: String {
        switch self {
        case .nba:               return "basketball/nba"
        case .euroLeague:        return "basketball/euroleague"
        case .premierLeague:     return "soccer/eng.1"
        case .championsLeague:   return "soccer/uefa.champions"
        case .laLiga:            return "soccer/esp.1"
        case .greekSuperLeague:  return "soccer/gre.1"
        case .worldCup:          return "soccer/fifa.world"
        }
    }

    var displayName: String {
        switch self {
        case .nba:               return "NBA"
        case .euroLeague:        return "EuroLeague"
        case .premierLeague:     return "Premier League"
        case .championsLeague:   return "Champions League"
        case .laLiga:            return "La Liga"
        case .greekSuperLeague:  return "Super League Greece"
        case .worldCup:          return "World Cup"
        }
    }

    /// Short badge initial shown on result rows.
    var badge: String {
        switch self {
        case .nba:               return "NBA"
        case .euroLeague:        return "EL"
        case .premierLeague:     return "PL"
        case .championsLeague:   return "CL"
        case .laLiga:            return "LL"
        case .greekSuperLeague:  return "GR"
        case .worldCup:          return "WC"
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
    let homeLogo: URL?
    let awayLogo: URL?
    let homeColor: String?        // hex, no leading '#'
    let awayColor: String?
    var homeID: String = ""
    var awayID: String = ""
}

struct FinishedGame: Identifiable {
    let id: String
    let homeTeam: String
    let awayTeam: String
    let homeScore: Int
    let awayScore: Int
    let league: League
    let link: URL?
    let homeLogo: URL?
    let awayLogo: URL?
    let homeColor: String?
    let awayColor: String?
    var homeID: String = ""
    var awayID: String = ""
}

/// A team the user follows, picked from a league's roster (Apple Sports style).
/// Matched by ESPN team id within its league, so "Inter" never catches
/// "Internacional" the way a name search would.
struct FollowedTeam: Codable, Hashable, Identifiable {
    let league: League
    let teamID: String
    let name: String
    let abbreviation: String
    let logo: URL?
    let color: String?
    var id: String { "\(league.rawValue):\(teamID)" }
}

// MARK: - Manager

@MainActor
final class SportsManager: ObservableObject {

    @Published private(set) var liveGames: [LiveGame] = []
    @Published private(set) var yesterdayResults: [FinishedGame] = []
    @Published private(set) var isPolling: Bool = false
    @Published private(set) var lastUpdated: Date?

    /// Master on/off for the whole sports module.
    @Published var isSportsEnabled: Bool {
        didSet {
            defaults.set(isSportsEnabled, forKey: Keys.enabled)
            if isSportsEnabled {
                Task { await refresh() }
            } else {
                liveGames = []
                yesterdayResults = []
            }
        }
    }

    /// Legacy free-text follows (substring match on team names).
    @Published var followedTeams: [String] {
        didSet { defaults.set(followedTeams, forKey: Keys.followedTeams); applyFilter() }
    }
    /// Teams picked from a league roster in Settings.
    @Published var myTeams: [FollowedTeam] {
        didSet {
            if let data = try? JSONEncoder().encode(myTeams) {
                defaults.set(data, forKey: Keys.myTeams)
            }
            applyFilter()   // re-filter what we have; no network round trip
        }
    }
    private var rosterCache: [League: [FollowedTeam]] = [:]
    /// Unfiltered results from the last fetch, so following or unfollowing a
    /// team just re-filters instead of re-downloading every league.
    private var rawLive: [LiveGame] = []
    private var rawYesterday: [FinishedGame] = []

    private func applyFilter() {
        liveGames = filterFollowed(rawLive, league: \.league, homeID: \.homeID, awayID: \.awayID,
                                   home: \.homeTeam, away: \.awayTeam,
                                   homeAbbr: \.homeAbbr, awayAbbr: \.awayAbbr)
        yesterdayResults = filterFollowed(rawYesterday, league: \.league, homeID: \.homeID, awayID: \.awayID,
                                          home: \.homeTeam, away: \.awayTeam,
                                          homeAbbr: { _ in "" }, awayAbbr: { _ in "" })
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
        static let myTeams = "notchly.sports.myTeams"
        static let enabledLeagues = "notchly.enabledLeagues"
        static let enabled = "notchly.sports.enabled"
        static let leaguesMigrationV2 = "notchly.leagues.migration.v2"
    }

    private var pollTask: Task<Void, Never>?

    init() {
        isSportsEnabled = (defaults.object(forKey: Keys.enabled) as? Bool) ?? true
        followedTeams = defaults.stringArray(forKey: Keys.followedTeams) ?? []
        myTeams = defaults.data(forKey: Keys.myTeams)
            .flatMap { try? JSONDecoder().decode([FollowedTeam].self, from: $0) } ?? []
        if let raw = defaults.array(forKey: Keys.enabledLeagues) as? [String], !raw.isEmpty {
            enabledLeagues = Set(raw.compactMap(League.init(rawValue:)))
        } else {
            enabledLeagues = Set(League.allCases)   // all on by default
        }

        // One-time migration: turn EuroLeague + Greek Super League on for
        // existing users when they're added (without re-enabling ones the user
        // deliberately switched off).
        if !defaults.bool(forKey: Keys.leaguesMigrationV2) {
            enabledLeagues.insert(.euroLeague)
            enabledLeagues.insert(.greekSuperLeague)
            defaults.set(true, forKey: Keys.leaguesMigrationV2)
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
        guard isSportsEnabled else { return }
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

    func isFollowing(_ team: FollowedTeam) -> Bool { myTeams.contains { $0.id == team.id } }

    func toggleFollow(_ team: FollowedTeam) {
        if let i = myTeams.firstIndex(where: { $0.id == team.id }) {
            myTeams.remove(at: i)
        } else {
            myTeams.append(team)
        }
    }

    /// Every team in a league, alphabetical. Cached for the session.
    /// Tries the league's /teams list first; ESPN's edge sometimes refuses
    /// that one, so the standings table (which names every team too) is the
    /// fallback.
    func roster(for league: League) async -> [FollowedTeam] {
        if let cached = rosterCache[league] { return cached }
        var raw: [ESPNTeam] = []
        if let data = await getJSON(baseURL + league.path + "/teams"),
           let decoded = try? JSONDecoder().decode(ESPNTeamsResponse.self, from: data) {
            raw = (decoded.sports?.first?.leagues?.first?.teams ?? []).compactMap(\.team)
        }
        if raw.isEmpty,
           let data = await getJSON("https://site.api.espn.com/apis/v2/sports/" + league.path + "/standings"),
           let node = try? JSONDecoder().decode(ESPNStandingsNode.self, from: data) {
            raw = node.allTeams
        }
        if raw.isEmpty { sportsLog.error("roster \(league.rawValue, privacy: .public): no teams from either endpoint") }

        var seen = Set<String>()
        let teams = raw
            .compactMap { t -> FollowedTeam? in
                guard let id = t.id, let name = t.displayName, seen.insert(id).inserted else { return nil }
                return FollowedTeam(league: league, teamID: id, name: name,
                                    abbreviation: t.abbreviation ?? String(name.prefix(3)).uppercased(),
                                    logo: (t.logos?.first?.href ?? t.logo).flatMap(URL.init(string:)),
                                    color: t.color)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if !teams.isEmpty { rosterCache[league] = teams }
        return teams
    }

    /// GET returning the body only when it's a 200 JSON response.
    private func getJSON(_ string: String) async -> Data? {
        guard let url = URL(string: string) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        let result = try? await URLSession.shared.data(for: request)
        guard let (data, response) = result,
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              (http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("json")
        else { return nil }
        return data
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

        // Fetch all enabled leagues concurrently instead of serially.
        let leagues = League.allCases.filter { enabledLeagues.contains($0) }
        let results = await withTaskGroup(of: (League, [ESPNEvent]?).self) { group in
            for league in leagues {
                group.addTask { [weak self] in
                    (league, await self?.fetchScoreboard(path: league.path, date: nil) ?? nil)
                }
            }
            var out: [(League, [ESPNEvent]?)] = []
            for await r in group { out.append(r) }
            return out
        }

        for (league, events) in results {
            if let events {
                anySuccess = true
                games += events.compactMap { liveGame(from: $0, league: league) }
            }
        }

        // On total network failure, keep the last cached result.
        // NOTCHLY_FAKE_SCORE=1 injects a live game (debug/screenshots).
        if ProcessInfo.processInfo.environment["NOTCHLY_FAKE_SCORE"] == "1" {
            anySuccess = true
            games.insert(LiveGame(id: "fake", homeTeam: "Los Angeles Lakers", awayTeam: "Boston Celtics",
                                  homeAbbr: "LAL", awayAbbr: "BOS", homeScore: 102, awayScore: 98,
                                  state: .live, statusDetail: "Q4 2:31", league: .nba, link: nil,
                                  homeLogo: nil, awayLogo: nil, homeColor: nil, awayColor: nil,
                                  homeID: "13", awayID: "2"), at: 0)
        }
        guard anySuccess else { return }
        rawLive = games
        applyFilter()
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

        let leagues = League.allCases.filter { enabledLeagues.contains($0) }
        let fetched = await withTaskGroup(of: (League, [ESPNEvent]?).self) { group in
            for league in leagues {
                group.addTask { [weak self] in
                    (league, await self?.fetchScoreboard(path: league.path, date: dateString) ?? nil)
                }
            }
            var out: [(League, [ESPNEvent]?)] = []
            for await r in group { out.append(r) }
            return out
        }

        for (league, events) in fetched {
            if let events {
                anySuccess = true
                results += events.compactMap { finishedGame(from: $0, league: league) }
            }
        }

        guard anySuccess else { return }
        rawYesterday = results
        applyFilter()
    }

    // MARK: - Networking

    /// Returns events on success (possibly empty), or nil on network failure.
    private func fetchScoreboard(path: String, date: String?) async -> [ESPNEvent]? {
        var urlString = baseURL + path + "/scoreboard"
        if let date { urlString += "?dates=\(date)" }
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12   // don't let one stalled endpoint hang a refresh

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
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

        // Keep games in the Live tab through the night: today's "sports day"
        // runs until 6 AM tomorrow (local time), so late US games that fall in
        // the early hours still count as today. Drop fixtures beyond that.
        if state == .pre,
           let date = Self.parseDate(event.date),
           !Self.isWithinTodayWindow(date) {
            return nil
        }

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
            link: firstLink(event),
            homeLogo: home.team?.logo.flatMap { URL(string: $0) },
            awayLogo: away.team?.logo.flatMap { URL(string: $0) },
            homeColor: home.team?.color,
            awayColor: away.team?.color,
            homeID: home.team?.id ?? "",
            awayID: away.team?.id ?? ""
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
            link: firstLink(event),
            homeLogo: home.team?.logo.flatMap { URL(string: $0) },
            awayLogo: away.team?.logo.flatMap { URL(string: $0) },
            homeColor: home.team?.color,
            awayColor: away.team?.color,
            homeID: home.team?.id ?? "",
            awayID: away.team?.id ?? ""
        )
    }

    /// True if `date` is within today's "sports day": from the start of today
    /// through 6 AM the next morning (local time), inclusive of 6 AM kickoffs.
    private static func isWithinTodayWindow(_ date: Date) -> Bool {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        guard let end = cal.date(byAdding: .hour, value: 30, to: start) else { return false }
        return date >= start && date <= end
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
                return Self.upcomingLabel(for: date)
            }
            return "Upcoming"
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
        // ESPN often omits seconds (e.g. "2026-08-21T19:00Z"), which the strict
        // ISO8601 parser rejects — so try a set of explicit UTC formats.
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        for fmt in ["yyyy-MM-dd'T'HH:mm'Z'", "yyyy-MM-dd'T'HH:mm:ss'Z'",
                    "yyyy-MM-dd'T'HH:mmZ", "yyyy-MM-dd'T'HH:mm:ssZ"] {
            f.dateFormat = fmt
            if let d = f.date(from: string) { return d }
        }
        let iso = ISO8601DateFormatter()
        return iso.date(from: string)
    }

    /// "Today 8:30 PM", "Tomorrow 8:30 PM", "Mon 8:30 PM", or "Aug 21 · 8:00 PM".
    private static func upcomingLabel(for date: Date) -> String {
        let cal = Calendar.current
        let timeF = DateFormatter()
        timeF.locale = Locale(identifier: "en_US_POSIX")
        timeF.dateFormat = "h:mm a"
        timeF.timeZone = .current
        let time = timeF.string(from: date)

        if cal.isDateInToday(date) { return "Today \(time)" }
        if cal.isDateInTomorrow(date) { return "Tomorrow \(time)" }

        let days = cal.dateComponents([.day], from: Date(), to: date).day ?? 0
        let other = DateFormatter()
        other.locale = Locale(identifier: "en_US_POSIX")
        other.timeZone = .current
        if days >= 0 && days < 6 {
            other.dateFormat = "EEE"            // weekday this week
            return "\(other.string(from: date)) \(time)"
        }
        other.dateFormat = "MMM d"               // further out
        return "\(other.string(from: date)) · \(time)"
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
        league: (T) -> League,
        homeID: (T) -> String,
        awayID: (T) -> String,
        home: (T) -> String,
        away: (T) -> String,
        homeAbbr: (T) -> String,
        awayAbbr: (T) -> String
    ) -> [T] {
        guard !followedTeams.isEmpty || !myTeams.isEmpty else { return games }   // none followed → show all
        let needles = followedTeams.map { $0.lowercased() }
        let picked = Set(myTeams.map(\.id))
        return games.filter { game in
            let lg = league(game).rawValue
            if picked.contains("\(lg):\(homeID(game))") || picked.contains("\(lg):\(awayID(game))") {
                return true
            }
            let haystacks = [home(game), away(game), homeAbbr(game), awayAbbr(game)]
                .map { $0.lowercased() }
            return needles.contains { needle in
                haystacks.contains { $0.contains(needle) }
            }
        }
    }
}

// MARK: - ESPN response (best-effort decoding)

private struct ESPNScoreboard: Decodable, Sendable {
    let events: [ESPNEvent]?
}

struct ESPNEvent: Decodable, Sendable {
    let id: String?
    let date: String?
    let status: ESPNStatus?
    let competitions: [ESPNCompetition]?
    let links: [ESPNLink]?
}

struct ESPNStatus: Decodable, Sendable {
    let displayClock: String?
    let period: Int?
    let type: ESPNStatusType?
}

struct ESPNStatusType: Decodable, Sendable {
    let state: String?
    let completed: Bool?
    let shortDetail: String?
    let detail: String?
}

struct ESPNCompetition: Decodable, Sendable {
    let competitors: [ESPNCompetitor]?
}

struct ESPNCompetitor: Decodable, Sendable {
    let homeAway: String?
    let score: String?
    let team: ESPNTeam?
}

struct ESPNTeam: Decodable, Sendable {
    let id: String?
    let displayName: String?
    let shortDisplayName: String?
    let abbreviation: String?
    let logo: String?
    let color: String?
    let logos: [ESPNLogo]?
}

struct ESPNLogo: Decodable, Sendable { let href: String? }

/// Standings are nested (league → conference/group → table); every level
/// may carry `children` and/or a `standings.entries` table.
private final class ESPNStandingsNode: Decodable, @unchecked Sendable {
    struct Table: Decodable { let entries: [Entry]? }
    struct Entry: Decodable { let team: ESPNTeam? }
    let children: [ESPNStandingsNode]?
    let standings: Table?
    var allTeams: [ESPNTeam] {
        (standings?.entries ?? []).compactMap(\.team) + (children ?? []).flatMap(\.allTeams)
    }
}

private struct ESPNTeamsResponse: Decodable, Sendable {
    struct Sport: Decodable, Sendable { let leagues: [LeagueBlock]? }
    struct LeagueBlock: Decodable, Sendable { let teams: [Wrapper]? }
    struct Wrapper: Decodable, Sendable { let team: ESPNTeam? }
    let sports: [Sport]?
}

struct ESPNLink: Decodable, Sendable {
    let href: String?
    let rel: [String]?
}

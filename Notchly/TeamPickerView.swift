//
//  TeamPickerView.swift
//  Notchly — follow teams, Apple Sports style
//
//  "My Teams" shows the followed teams as logo chips; "Add Teams…" opens a
//  sheet with a league switcher, a search field and the league's full roster,
//  where each team is one click to follow or unfollow.
//

import SwiftUI

// MARK: - My Teams (inline in the Sports settings pane)

struct MyTeamsSection: View {
    @ObservedObject var sports: SportsManager
    @State private var showPicker = ProcessInfo.processInfo.environment["NOTCHLY_TEAM_PICKER"] == "1"

    private let columns = [GridItem(.adaptive(minimum: 78), spacing: 10)]

    var body: some View {
        SwiftUI.Section {
            if sports.myTeams.isEmpty && sports.followedTeams.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "star.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.yellow)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No teams yet")
                        Text("Every game in your leagues is shown until you pick some.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(sports.myTeams) { team in
                        TeamChip(team: team) { sports.toggleFollow(team) }
                    }
                    // Older free-text follows, so they can still be removed.
                    ForEach(Array(sports.followedTeams.enumerated()), id: \.offset) { i, name in
                        LegacyChip(name: name) { sports.removeTeam(at: i) }
                    }
                }
                .padding(.vertical, 4)
            }

            Button {
                showPicker = true
            } label: {
                Label("Add Teams…", systemImage: "plus.circle.fill")
            }
        } header: {
            Text("My Teams")
        } footer: {
            Text("Only games with your teams appear in the notch and the scores list.")
        }
        .sheet(isPresented: $showPicker) {
            TeamPickerSheet(sports: sports)
        }
    }
}

private struct TeamChip: View {
    let team: FollowedTeam
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .topTrailing) {
                TeamLogo(url: team.logo, abbr: team.abbreviation, color: team.color, size: 44)
                if hovering {
                    Button(action: remove) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .gray)
                    }
                    .buttonStyle(.plain)
                    .offset(x: 6, y: -6)
                    .help("Unfollow \(team.name)")
                }
            }
            Text(team.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: 28, alignment: .top)
            Text(team.league.badge)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(width: 78)
        .onHover { hovering = $0 }
    }
}

private struct LegacyChip: View {
    let name: String
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .topTrailing) {
                Circle().fill(.quaternary).frame(width: 44, height: 44)
                    .overlay(Image(systemName: "textformat").foregroundStyle(.secondary))
                if hovering {
                    Button(action: remove) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .gray)
                    }
                    .buttonStyle(.plain)
                    .offset(x: 6, y: -6)
                }
            }
            Text(name).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                .frame(height: 28, alignment: .top)
            Text("Name match").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
        }
        .frame(width: 78)
        .onHover { hovering = $0 }
    }
}

// MARK: - Picker sheet

struct TeamPickerSheet: View {
    @ObservedObject var sports: SportsManager
    @Environment(\.dismiss) private var dismiss

    @State private var league: League = .premierLeague
    @State private var roster: [FollowedTeam] = []
    @State private var loading = false
    @State private var query = ""

    private var filtered: [FollowedTeam] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return roster }
        return roster.filter {
            $0.name.localizedCaseInsensitiveContains(q)
                || $0.abbreviation.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title row
            HStack {
                Text("Add Teams").font(.title3.weight(.semibold))
                Spacer()
                Text("\(sports.myTeams.count) following")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 10)

            // League switcher
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(League.allCases) { lg in
                        let on = lg == league
                        Button { league = lg } label: {
                            Text(lg.displayName)
                                .font(.callout.weight(on ? .semibold : .regular))
                                .padding(.horizontal, 11).padding(.vertical, 5)
                                .background(Capsule().fill(on ? Color.accentColor : Color.secondary.opacity(0.15)))
                                .foregroundStyle(on ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18)
            }
            .padding(.bottom, 10)

            // Search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search \(league.displayName)", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
            .padding(.horizontal, 18).padding(.bottom, 8)

            Divider()

            // Roster
            Group {
                if loading && roster.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if roster.isEmpty {
                    ContentUnavailableView("Couldn't load teams",
                                           systemImage: "wifi.exclamationmark",
                                           description: Text("Check your connection and try another league."))
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List(filtered) { team in
                        TeamRow(team: team, following: sports.isFollowing(team)) {
                            withAnimation(.snappy(duration: 0.2)) { sports.toggleFollow(team) }
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 460, height: 540)
        .task(id: league) {
            loading = true
            roster = []
            roster = await sports.roster(for: league)
            loading = false
        }
    }
}

private struct TeamRow: View {
    let team: FollowedTeam
    let following: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                TeamLogo(url: team.logo, abbr: team.abbreviation, color: team.color, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(team.name)
                    Text(team.abbreviation).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: following ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(following ? Color.accentColor : .secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Logo

struct TeamLogo: View {
    let url: URL?
    let abbr: String
    let color: String?
    let size: CGFloat

    private var tint: Color {
        guard let hex = color, let v = UInt32(hex, radix: 16) else { return .gray }
        return Color(red: Double((v >> 16) & 0xFF) / 255,
                     green: Double((v >> 8) & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255)
    }

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFit()
            } else {
                Circle().fill(tint.opacity(0.85))
                    .overlay(Text(abbr.prefix(3))
                        .font(.system(size: size * 0.28, weight: .bold, design: .rounded))
                        .foregroundStyle(.white))
            }
        }
        .frame(width: size, height: size)
    }
}

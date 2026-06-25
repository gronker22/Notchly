//
//  SettingsView.swift
//  Notchly — Settings
//
//  Sports settings: per-league toggles, followed teams, and a "Test fetch"
//  button. Opened in its own window via SettingsWindowPresenter (the app is an
//  accessory with no menu bar, so the standard Settings scene isn't reachable).
//

import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var sports: SportsManager
    @State private var newTeam = ""
    @State private var testResult = ""
    @State private var testing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                leaguesSection
                Divider()
                teamsSection
                Divider()
                notificationsSection
                Divider()
                testSection
            }
            .padding(20)
        }
        .frame(width: 360, height: 460)
    }

    // MARK: Leagues

    private var leaguesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Leagues").font(.headline)
            ForEach(League.allCases) { league in
                Toggle(league.displayName, isOn: Binding(
                    get: { sports.isEnabled(league) },
                    set: { sports.setEnabled(league, $0) }
                ))
                .toggleStyle(.switch)
            }
        }
    }

    // MARK: Followed teams

    private var teamsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Followed teams").font(.headline)
            Text("Only games involving these teams are shown. Leave empty to show all.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                TextField("Add a team (e.g. Lakers, Man City)", text: $newTeam)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTeam)
                Button("Add", action: addTeam)
                    .disabled(newTeam.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if sports.followedTeams.isEmpty {
                Text("No teams followed").font(.caption).foregroundStyle(.tertiary)
            } else {
                ForEach(Array(sports.followedTeams.enumerated()), id: \.offset) { index, team in
                    HStack {
                        Text(team)
                        Spacer()
                        Button {
                            sports.removeTeam(at: index)
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func addTeam() {
        sports.addTeam(newTeam)
        newTeam = ""
    }

    // MARK: Notifications (Full Disk Access)

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notification peek").font(.headline)
            Text("To briefly show incoming notifications in the notch, Notchly needs Full Disk Access (macOS keeps notifications in a protected database). Enable Notchly there, then relaunch.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Open Full Disk Access settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    // MARK: Test fetch

    private var testSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Debug").font(.headline)
            HStack {
                Button {
                    testing = true
                    Task {
                        let result = await sports.testFetch()
                        testResult = result
                        testing = false
                    }
                } label: {
                    Text(testing ? "Fetching…" : "Test fetch")
                }
                .disabled(testing)

                if !testResult.isEmpty {
                    Text(testResult).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Settings window presenter

@MainActor
enum SettingsWindowPresenter {
    private static var window: NSWindow?

    static func show(sports: SportsManager) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "Notchly Settings"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: SettingsView(sports: sports))
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

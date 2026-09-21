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
    @ObservedObject private var settings = NotchSettings.shared
    @StateObject private var updater = UpdateChecker()
    @State private var newTeam = ""
    @State private var testResult = ""
    @State private var testing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                generalSection
                Divider()
                modulesSection
                Divider()
                leaguesSection
                Divider()
                teamsSection
                Divider()
                updatesSection
                Divider()
                testSection
                Divider()
                quitSection
            }
            .padding(20)
        }
        .frame(width: 380, height: 560)
    }

    // MARK: General

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("General").font(.headline)
            Toggle("Launch Notchly at login", isOn: $settings.launchAtLogin)
            Text("Notchly starts automatically when you log in. (May need re-enabling after reinstalling an unsigned build.)")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Modules

    private var modulesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Modules").font(.headline)
            Text("Turn off what you don't use — disabled modules stop polling entirely (saves battery) and disappear from the notch.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Now Playing (music)", isOn: $settings.showNowPlaying)
            Toggle("System stats (CPU / RAM / network / Wi-Fi)", isOn: $settings.showSystemStats)
            Toggle("Pomodoro timer", isOn: $settings.showPomodoro)
            Toggle("Calendar", isOn: $settings.showCalendar)
            Toggle("Mic / camera indicator", isOn: $settings.showMediaAccess)
            Toggle("Clipboard history", isOn: $settings.showClipboard)
            Text("Changes to which modules run take effect after you quit and reopen Notchly.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    // MARK: Updates

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Updates").font(.headline)
            HStack {
                Button {
                    updater.check()
                } label: {
                    Text(updater.checking ? "Checking…" : "Check for updates")
                }
                .disabled(updater.checking)
                Text("Current: v\(AppInfo.version)").font(.caption).foregroundStyle(.tertiary)
            }
            if !updater.status.isEmpty {
                Text(updater.status).font(.caption).foregroundStyle(.secondary)
            }
            if let url = updater.updateURL {
                Button("Download the latest version") { NSWorkspace.shared.open(url) }
            }
        }
    }

    // MARK: Quit

    /// An always-available off switch. (There's also a menu bar icon → Quit.)
    private var quitSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Turn off Notchly").font(.headline)
            Text("Quits the app completely. Reopen it any time from your Applications folder.")
                .font(.caption).foregroundStyle(.secondary)
            Button(role: .destructive) {
                NSApp.terminate(nil)
            } label: {
                Label("Quit Notchly", systemImage: "power")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .tint(.red)
        }
    }

    // MARK: Leagues

    private var leaguesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Show sports", isOn: Binding(
                get: { sports.isSportsEnabled },
                set: { sports.isSportsEnabled = $0 }
            ))
            .toggleStyle(.switch)
            .font(.headline)

            if sports.isSportsEnabled {
                Divider()
                Text("Leagues").font(.subheadline).foregroundStyle(.secondary)
                ForEach(League.allCases) { league in
                    Toggle(league.displayName, isOn: Binding(
                        get: { sports.isEnabled(league) },
                        set: { sports.setEnabled(league, $0) }
                    ))
                    .toggleStyle(.switch)
                }
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

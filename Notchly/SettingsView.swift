//
//  SettingsView.swift
//  Notchly — Settings
//
//  Laid out like System Settings on modern macOS: a source-list sidebar of
//  categories on the left, and a grouped `Form` on the right. `.formStyle(
//  .grouped)` is what gives the inset rounded cards, the proper row insets and
//  the system's own label/control alignment, so the window reads as native
//  rather than as a stack of headlines and dividers in a ScrollView.
//
//  Opened in its own window via SettingsWindowPresenter (the app is an
//  accessory with no menu bar, so the standard Settings scene isn't reachable).
//

import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var sports: SportsManager
    @ObservedObject private var settings = NotchSettings.shared
    @StateObject private var updater = UpdateChecker()

    // NOTCHLY_SETTINGS_SECTION=sports opens a given pane (debug/screenshots).
    @State private var section: Section = Section(
        rawValue: ProcessInfo.processInfo.environment["NOTCHLY_SETTINGS_SECTION"] ?? "") ?? .general
    @State private var testResult = ""
    @State private var testing = false

    enum Section: String, CaseIterable, Identifiable {
        case general, modules, features, sports, updates, about
        var id: Self { self }

        var title: String {
            switch self {
            case .general:  return "General"
            case .modules:  return "Modules"
            case .features: return "Guide"
            case .sports:   return "Sports"
            case .updates:  return "Updates"
            case .about:    return "About"
            }
        }

        var icon: String {
            switch self {
            case .general:  return "gearshape.fill"
            case .modules:  return "square.grid.2x2.fill"
            case .features: return "questionmark.circle.fill"
            case .sports:   return "sportscourt.fill"
            case .updates:  return "arrow.down.circle.fill"
            case .about:    return "info.circle.fill"
            }
        }

        /// The tinted rounded square macOS uses beside each sidebar row.
        var tint: Color {
            switch self {
            case .general:  return Color(red: 0.45, green: 0.50, blue: 0.58)
            case .modules:  return Color(red: 0.36, green: 0.60, blue: 1.00)
            case .features: return Color(red: 0.95, green: 0.45, blue: 0.55)
            case .sports:   return Color(red: 0.30, green: 0.78, blue: 0.47)
            case .updates:  return Color(red: 0.98, green: 0.65, blue: 0.20)
            case .about:    return Color(red: 0.68, green: 0.56, blue: 0.98)
            }
        }
    }

    /// One row of the feature guide.
    private struct FeatureDoc: Identifiable {
        let id = UUID()
        let icon: String
        let tint: Color
        let name: String
        let what: String
        let how: String
        let note: String?
    }

    private static let featureDocs: [FeatureDoc] = [
        .init(icon: "cursorarrow.rays", tint: .gray, name: "The notch itself",
              what: "Hover the top-centre notch and it expands into a panel; move away and it shrinks back.",
              how: "When nothing is happening it shrinks to cover just the camera housing, so it's invisible. It widens on its own when a timer is running, a game is live, the mic or camera is in use, or a notification arrives.",
              note: "It never steals your clicks — the panel is click-through whenever it's closed."),
        .init(icon: "music.note", tint: Color(red: 1.0, green: 0.42, blue: 0.48), name: "Now Playing",
              what: "Shows what's playing in Music or Spotify, with artwork, a scrubber and transport controls.",
              how: "Drag the progress bar to seek. The bar only appears when something is actually playing.",
              note: "Needs the Automation permission the first time, so it can ask the player what's on."),
        .init(icon: "calendar", tint: Color(red: 0.40, green: 0.64, blue: 1.0), name: "Calendar",
              what: "Your next event, with a countdown.",
              how: "If the event has a video link, a Join button appears and opens the meeting directly. The row turns orange when the event is under five minutes away.",
              note: "Needs Calendar access."),
        .init(icon: "brain.head.profile", tint: Color(red: 1.0, green: 0.45, blue: 0.35), name: "Focus timer",
              what: "A pomodoro timer that alternates focus and break periods.",
              how: "Play/pause, reset, and −/+ to change the length while paused. The ring around the collapsed pill shows progress, so you can see it without opening the panel.",
              note: nil),
        .init(icon: "doc.on.clipboard", tint: Color(red: 0.55, green: 0.78, blue: 1.0), name: "Clipboard history",
              what: "Keeps what you've recently copied so you can paste something from a few steps back.",
              how: "Click an entry to copy it again. Pin the ones you want kept. How many are kept is set in General ▸ Limits.",
              note: nil),
        .init(icon: "gauge.with.dots.needle.33percent", tint: Color(red: 0.98, green: 0.65, blue: 0.20), name: "System stats",
              what: "CPU, memory, network throughput and Wi-Fi at a glance.",
              how: "A quick peek so you don't have to open Activity Monitor.",
              note: nil),
        .init(icon: "speaker.wave.2.fill", tint: Color(red: 0.68, green: 0.56, blue: 0.98), name: "Volume & brightness HUD",
              what: "Replaces the big square overlay macOS throws in the middle of your screen.",
              how: "Change volume or brightness and the level appears in the notch instead. How long it stays is adjustable in General ▸ Limits.",
              note: "Volume is instant. Brightness is read through a private system API, so it may stop working on a future macOS — it fails quietly if so."),
        .init(icon: "bell.fill", tint: Color(red: 1.0, green: 0.74, blue: 0.35), name: "Notifications",
              what: "Mirrors incoming notification banners into the panel.",
              how: "Turn it on in Modules and grant Accessibility access.",
              note: "macOS has no supported way to read other apps' notifications, so this reads Notification Center's own window. It's off by default and it's the only feature that needs Accessibility."),
        .init(icon: "tray.fill", tint: Color(red: 0.35, green: 0.85, blue: 0.55), name: "File shelf",
              what: "Parks files so you can carry them between apps, windows and Spaces.",
              how: "Three ways in: drop files on the menu bar icon, press Add in the shelf, or drop them into the open panel. Drag a chip back out to move the file somewhere; double-click to reveal it in Finder.",
              note: "Dropping on the notch strip itself often loses to Mission Control, which the system triggers for gestures near the top of the screen — that's why the menu bar icon exists."),
        .init(icon: "sportscourt.fill", tint: Color(red: 0.30, green: 0.80, blue: 0.46), name: "Live scores",
              what: "Live and upcoming games for the leagues you choose.",
              how: "Collapsed by default — the Scores row shows how many games are live, so you only open it when there's something on. Pick your teams in Settings → Sports → Add Teams… and only their games show up, in the panel and as a one-line score on the left of the notch.",
              note: nil),
        .init(icon: "crown.fill", tint: Color(red: 0.76, green: 0.62, blue: 1.0), name: "Chess",
              what: "A full chess engine with legal-move validation, plus multiplayer.",
              how: "Play the computer, or Play a friend: find someone on the same Wi-Fi, or swap a five-character room code to play across different networks.",
              note: "Move generation is verified against standard perft counts to depth 4."),
        .init(icon: "suit.heart.fill", tint: Color(red: 1.0, green: 0.42, blue: 0.48), name: "Poker & blackjack",
              what: "Texas Hold'em with side pots and an AI coach, plus blackjack.",
              how: "Hold'em can be played solo against bots, heads-up against one friend, or at a table of up to six. Set the number of seats and whether empty ones fill with bots, then host over Wi-Fi or share a room code.",
              note: "Over a room code the cards travel via a public relay, so it's fine among friends but not cheat-proof. Same-network play is encrypted."),
    ]

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $section) { item in
                Label {
                    Text(item.title)
                } icon: {
                    Image(systemName: item.icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(item.tint)
                        )
                }
                .tag(item)
            }
            .navigationSplitViewColumnWidth(176)
        } detail: {
            Group {
                switch section {
                case .general: generalForm
                case .modules: modulesForm
                case .features: featuresForm
                case .sports:  sportsForm
                case .updates: updatesForm
                case .about:   aboutForm
                }
            }
            .formStyle(.grouped)
            .navigationTitle(section.title)
        }
        .frame(width: 680, height: 520)
    }

    // MARK: - General

    private var generalForm: some View {
        Form {
            SwiftUI.Section {
                Toggle("Launch Notchly at login", isOn: $settings.launchAtLogin)
            } footer: {
                Text("Notchly starts automatically when you log in. May need re-enabling after reinstalling an unsigned build.")
            }

            SwiftUI.Section {
                Toggle("Shrink to the notch when idle", isOn: $settings.hugNotchWhenIdle)
                Toggle("Open the shelf when dragging files to the notch", isOn: $settings.dragOpensShelf)
                Toggle("Show update banner in the panel", isOn: $settings.showUpdateBanner)
            } header: {
                Text("Appearance")
            } footer: {
                Text("When idle, the pill shrinks to cover just the camera housing. Turn this off to keep the full-width pill visible at all times.")
            }

            SwiftUI.Section {
                LabeledContent("HUD on screen for") {
                    HStack(spacing: 10) {
                        Slider(value: $settings.hudDuration, in: 0.6...4.0, step: 0.2)
                            .frame(width: 180)
                        Text(String(format: "%.1fs", settings.hudDuration))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Stepper("Clipboard entries: \(settings.clipboardLimit)",
                        value: $settings.clipboardLimit, in: 3...25)
                Stepper("Shelf capacity: \(settings.shelfLimit) files",
                        value: $settings.shelfLimit, in: 4...40)
            } header: {
                Text("Limits")
            } footer: {
                Text("How long the volume and brightness HUD lingers, and how much history the clipboard and shelf keep.")
            }

            SwiftUI.Section {
                Button(role: .destructive) {
                    NSApp.terminate(nil)
                } label: {
                    Label("Quit Notchly", systemImage: "power")
                }
            } header: {
                Text("Turn off Notchly")
            } footer: {
                Text("Quits the app completely. Reopen it any time from your Applications folder, or from the menu bar icon.")
            }
        }
    }

    // MARK: - Modules

    private var modulesForm: some View {
        Form {
            SwiftUI.Section {
                Toggle("Now Playing", isOn: $settings.showNowPlaying)
                Toggle("Calendar", isOn: $settings.showCalendar)
                Toggle("Focus timer", isOn: $settings.showPomodoro)
                Toggle("Clipboard history", isOn: $settings.showClipboard)
                Toggle("System stats", isOn: $settings.showSystemStats)
                Toggle("Mic / camera indicator", isOn: $settings.showMediaAccess)
                Toggle("Volume & brightness HUD", isOn: $settings.showSystemHUD)
            } header: {
                Text("Show in the notch")
            } footer: {
                Text("Turning a module off stops its polling entirely, which saves battery as well as decluttering the panel. Changes take effect after you quit and reopen Notchly.")
            }

            SwiftUI.Section {
                Toggle("Notifications in the notch", isOn: $settings.showNotifications)

                if settings.showNotifications && !NotificationWatcher.hasAccessibility {
                    LabeledContent("Accessibility") {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Button("Grant access…") {
                                NotificationWatcher.requestAccessibility()
                                NSWorkspace.shared.open(NotchView.accessibilityURL)
                            }
                        }
                    }
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text(settings.showNotifications && !NotificationWatcher.hasAccessibility
                     ? "Notchly needs Accessibility access to read notification banners. Nothing is mirrored until it's granted."
                     : "Mirrors incoming banners into the panel. Requires Accessibility access — the only permission Notchly asks for beyond Calendar and media control.")
            }
        }
    }

    // MARK: - Feature guide

    private var featuresForm: some View {
        Form {
            SwiftUI.Section {
                Text("Every part of Notchly, what it does and how to use it.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Self.featureDocs) { doc in
                SwiftUI.Section {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(doc.what)
                        Text(doc.how)
                            .foregroundStyle(.secondary)
                        if let note = doc.note {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "info.circle")
                                    .foregroundStyle(.tertiary)
                                Text(note)
                                    .foregroundStyle(.tertiary)
                            }
                            .font(.callout)
                        }
                    }
                    .padding(.vertical, 2)
                } header: {
                    HStack(spacing: 7) {
                        Image(systemName: doc.icon)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 17, height: 17)
                            .background(RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                                .fill(doc.tint))
                        Text(doc.name)
                    }
                }
            }
        }
    }

    // MARK: - Sports

    private var sportsForm: some View {
        Form {
            SwiftUI.Section {
                Toggle("Show sports scores", isOn: Binding(
                    get: { sports.isSportsEnabled },
                    set: { sports.isSportsEnabled = $0 }
                ))
            } footer: {
                Text("When off, Notchly stops fetching scores altogether.")
            }

            if sports.isSportsEnabled {
                MyTeamsSection(sports: sports)

                SwiftUI.Section("Leagues") {
                    ForEach(League.allCases) { league in
                        Toggle(league.displayName, isOn: Binding(
                            get: { sports.isEnabled(league) },
                            set: { sports.setEnabled(league, $0) }
                        ))
                    }
                }

                SwiftUI.Section {
                    LabeledContent("Connection") {
                        HStack(spacing: 8) {
                            Button(testing ? "Fetching…" : "Test fetch") {
                                testing = true
                                Task {
                                    let result = await sports.testFetch()
                                    testResult = result
                                    testing = false
                                }
                            }
                            .disabled(testing)
                            if !testResult.isEmpty {
                                Text(testResult)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Diagnostics")
                }
            }
        }
    }

    // MARK: - Updates

    private var updatesForm: some View {
        Form {
            SwiftUI.Section {
                LabeledContent("Installed version") {
                    Text("v\(AppInfo.version)").foregroundStyle(.secondary)
                }
                LabeledContent("Check") {
                    Button(updater.checking ? "Checking…" : "Check now") {
                        updater.check()
                    }
                    .disabled(updater.checking)
                }
                if !updater.status.isEmpty {
                    Text(updater.status)
                        .foregroundStyle(.secondary)
                }
                if let url = updater.updateURL {
                    Button("Download the latest version") {
                        NSWorkspace.shared.open(url)
                    }
                }
            } footer: {
                Text("Notchly is distributed through GitHub Releases and can't update itself, so this checks the latest tag and opens the download page.")
            }
        }
    }

    // MARK: - About

    private var aboutForm: some View {
        Form {
            SwiftUI.Section {
                HStack(spacing: 14) {
                    Image(systemName: "rectangle.topthird.inset.filled")
                        .font(.system(size: 26))
                        .foregroundStyle(.white)
                        .frame(width: 54, height: 54)
                        .background(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .fill(LinearGradient(
                                    colors: [Color(red: 0.30, green: 0.32, blue: 0.46),
                                             Color(red: 0.10, green: 0.10, blue: 0.16)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                        )
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Notchly")
                            .font(.title2.weight(.semibold))
                        Text("Version \(AppInfo.version)")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 6)
            }

            SwiftUI.Section {
                Button("Open the project on GitHub") {
                    NSWorkspace.shared.open(AppInfo.releasesURL)
                }
            } footer: {
                Text("Turns the MacBook notch into a hub for your music, calendar, scores, clipboard and files.")
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
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.title = "Notchly Settings"
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: SettingsView(sports: sports))
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

//
//  NotchSettings.swift
//  Notchly — shared user settings
//
//  One observable store for cross-cutting preferences: which modules are enabled
//  (so disabled ones stop polling entirely — good for battery *and* declutter)
//  and whether Notchly launches at login. Backed by UserDefaults; a single
//  `.shared` instance is observed by both the notch and the Settings window.
//

import Foundation
import Combine
import ServiceManagement

@MainActor
final class NotchSettings: ObservableObject {
    static let shared = NotchSettings()

    private let defaults = UserDefaults.standard

    // MARK: - Module toggles (default ON, except heavier/optional ones)

    @Published var showPomodoro: Bool      { didSet { persist(\.showPomodoro,   "notchly.mod.pomodoro") } }
    @Published var showCalendar: Bool      { didSet { persist(\.showCalendar,   "notchly.mod.calendar") } }
    @Published var showWiFi: Bool          { didSet { persist(\.showWiFi,       "notchly.mod.wifi") } }
    @Published var showMediaAccess: Bool   { didSet { persist(\.showMediaAccess,"notchly.mod.media") } }
    @Published var showClipboard: Bool     { didSet { persist(\.showClipboard,  "notchly.mod.clipboard") } }
    @Published var showNowPlaying: Bool    { didSet { persist(\.showNowPlaying, "notchly.mod.nowplaying") } }
    @Published var showNotifications: Bool { didSet { persist(\.showNotifications,"notchly.mod.notifications") } }
    @Published var showSystemStats: Bool   { didSet { persist(\.showSystemStats,"notchly.mod.sysstats") } }

    // MARK: - Onboarding

    @Published var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: "notchly.onboarded") }
    }

    // MARK: - Multiplayer

    /// Display name others see when you're available to play chess nearby.
    @Published var multiplayerName: String {
        didSet {
            let trimmed = multiplayerName.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(trimmed.isEmpty ? Self.defaultPlayerName : trimmed, forKey: "notchly.mp.name")
        }
    }

    static var defaultPlayerName: String {
        let host = Host.current().localizedName ?? NSFullUserName()
        return host.isEmpty ? "Player" : host
    }

    // MARK: - Launch at login

    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            applyLaunchAtLogin(launchAtLogin)
        }
    }

    private init() {
        // First run has no stored values → default modules ON.
        let store = UserDefaults.standard
        func flag(_ key: String) -> Bool { store.object(forKey: key) == nil ? true : store.bool(forKey: key) }
        showPomodoro      = flag("notchly.mod.pomodoro")
        showCalendar      = flag("notchly.mod.calendar")
        showWiFi          = flag("notchly.mod.wifi")
        showMediaAccess   = flag("notchly.mod.media")
        showClipboard     = flag("notchly.mod.clipboard")
        showNowPlaying    = flag("notchly.mod.nowplaying")
        showNotifications = flag("notchly.mod.notifications")
        showSystemStats   = flag("notchly.mod.sysstats")
        hasCompletedOnboarding = store.bool(forKey: "notchly.onboarded")
        multiplayerName = store.string(forKey: "notchly.mp.name") ?? Self.defaultPlayerName

        // Reflect the actual registered state so the toggle isn't out of sync.
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func persist(_ keyPath: KeyPath<NotchSettings, Bool>, _ key: String) {
        defaults.set(self[keyPath: keyPath], forKey: key)
    }

    // MARK: - SMAppService

    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else       { try SMAppService.mainApp.unregister() }
        } catch {
            // Re-sync the published value to the real state if the OS refused.
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

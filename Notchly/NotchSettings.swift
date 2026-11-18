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
    @Published var showMediaAccess: Bool   { didSet { persist(\.showMediaAccess,"notchly.mod.media") } }
    @Published var showClipboard: Bool     { didSet { persist(\.showClipboard,  "notchly.mod.clipboard") } }
    @Published var showNowPlaying: Bool    { didSet { persist(\.showNowPlaying, "notchly.mod.nowplaying") } }
    @Published var showSystemStats: Bool   { didSet { persist(\.showSystemStats,"notchly.mod.sysstats") } }
    @Published var showSystemHUD: Bool     { didSet { persist(\.showSystemHUD,  "notchly.mod.hud") } }

    /// Off by default: the only module that costs an Accessibility prompt.
    @Published var showNotifications: Bool { didSet { persist(\.showNotifications, "notchly.mod.notifications") } }

    /// Whether the sports section is expanded in the panel. Collapsed by
    /// default — scores are the reason to open Notchly occasionally, not every
    /// time, and a full score list at the top made the panel open tall.
    @Published var sportsExpanded: Bool { didSet { persist(\.sportsExpanded, "notchly.sports.expanded") } }

    // MARK: - Appearance / behaviour

    /// Shrink the collapsed pill back to the hardware notch when nothing is
    /// live. Off = always show the full-width pill.
    @Published var hugNotchWhenIdle: Bool { didSet { persist(\.hugNotchWhenIdle, "notchly.idle.hug") } }

    /// Open the shelf automatically when a file is dragged toward the notch.
    /// Off = dragging files near the top of the screen does nothing; files can
    /// still be added with the Add button or the menu bar icon.
    @Published var dragOpensShelf: Bool { didSet { persist(\.dragOpensShelf, "notchly.shelf.dragopen") } }

    /// Show the "Update available" banner at the top of the panel.
    @Published var showUpdateBanner: Bool { didSet { persist(\.showUpdateBanner, "notchly.update.banner") } }

    /// How long the volume/brightness HUD stays on screen, in seconds.
    @Published var hudDuration: Double {
        didSet { defaults.set(hudDuration, forKey: "notchly.hud.duration") }
    }

    /// How many clipboard entries to keep.
    @Published var clipboardLimit: Int {
        didSet { defaults.set(clipboardLimit, forKey: "notchly.clipboard.limit") }
    }

    /// How many files the shelf holds before the oldest drops off.
    @Published var shelfLimit: Int {
        didSet { defaults.set(shelfLimit, forKey: "notchly.shelf.limit") }
    }

    // MARK: - Onboarding

    @Published var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: "notchly.onboarded") }
    }

    // MARK: - Multiplayer (chess)

    /// Display name others see when you're available to play nearby / online.
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
        showMediaAccess   = flag("notchly.mod.media")
        showClipboard     = flag("notchly.mod.clipboard")
        showNowPlaying    = flag("notchly.mod.nowplaying")
        showSystemStats   = flag("notchly.mod.sysstats")
        showSystemHUD     = flag("notchly.mod.hud")
        // Opt-in, not opt-out — it needs Accessibility, so default OFF.
        showNotifications = store.bool(forKey: "notchly.mod.notifications")
        sportsExpanded    = store.bool(forKey: "notchly.sports.expanded")
        hugNotchWhenIdle  = flag("notchly.idle.hug")
        showUpdateBanner  = flag("notchly.update.banner")
        dragOpensShelf    = flag("notchly.shelf.dragopen")
        let hud = store.double(forKey: "notchly.hud.duration")
        hudDuration = hud > 0 ? hud : 1.6
        let clip = store.integer(forKey: "notchly.clipboard.limit")
        clipboardLimit = clip > 0 ? clip : 8
        let shelf = store.integer(forKey: "notchly.shelf.limit")
        shelfLimit = shelf > 0 ? shelf : 12
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

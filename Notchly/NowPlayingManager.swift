//
//  NowPlayingManager.swift
//  Notchly — Now Playing (Tahoe-compatible)
//
//  Apple removed access to the private MediaRemote framework for third-party
//  apps in macOS 15.4+ (on macOS 26 it returns "Operation not permitted"). So
//  instead of the system-wide private API we read the two players that expose a
//  scripting interface — Spotify and Apple Music — via AppleScript.
//
//  Permission: the first query triggers a TCC prompt ("Notchly wants to control
//  Spotify/Music"). Needs NSAppleEventsUsageDescription. We never *launch* a
//  player — we only script it when it's already running (checked via NSWorkspace).
//
//  ⚠️ AppleScript round-trips can be slow (and the first one blocks on a consent
//  dialog), so ALL scripting runs on a background serial queue; only the parsed
//  result is published back on the main actor.
//

import Foundation
import AppKit
import Combine

/// The two scriptable players. Declared outside the @MainActor class so it (and
/// its helpers) can be used from the background scripting queue.
private enum NowPlayingPlayer: Sendable {
    case spotify, music
    var bundleID: String {
        switch self {
        case .spotify: return "com.spotify.client"
        case .music:   return "com.apple.Music"
        }
    }
    var appName: String {
        switch self {
        case .spotify: return "Spotify"
        case .music:   return "Music"
        }
    }
}

/// Plain value type carried from the background scripting queue to the main
/// actor — no reference to `self`, so it's safe to hop actors with.
private struct NowPlayingSnapshot: Sendable {
    let player: NowPlayingPlayer
    let isPlaying: Bool
    let title: String
    let artist: String
    let artworkURL: String?
}

@MainActor
final class NowPlayingManager: ObservableObject {

    @Published var title: String = "Nothing playing"
    @Published var artist: String = ""
    @Published var artwork: NSImage? = nil
    @Published var isPlaying: Bool = false
    @Published var hasTrack: Bool = false

    private var timer: Timer?
    private var active = false
    private var lastArtworkURL: String?

    /// Serial queue for all (blocking) AppleScript work.
    private let scriptQueue = DispatchQueue(label: "com.notchly.nowplaying.applescript")

    // MARK: - Lifecycle

    /// One-shot prime so the panel has something to show the first time it opens.
    /// The repeating poll is expensive (AppleScript IPC to Spotify/Music), so it
    /// runs only while the expanded panel is visible — driven by `setActive`.
    func start() {
        refresh()
    }

    /// Start/stop the 1.5s poll. Called with `true` when the notch expands and
    /// `false` when it collapses, so a closed notch does zero AppleScript work.
    func setActive(_ active: Bool) {
        guard active != self.active else { return }
        self.active = active
        if active {
            let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
            refresh()
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    // MARK: - Transport controls

    func togglePlayPause() { runControl("playpause") }
    func nextTrack()       { runControl("next track") }
    func previousTrack()   { runControl("previous track") }

    private func runControl(_ command: String) {
        scriptQueue.async { [weak self] in
            guard let player = NowPlayingScripting.pickPlayer() else { return }
            _ = NowPlayingScripting.runAppleScript("tell application \"\(player.appName)\" to \(command)")
            // Reflect the change quickly rather than waiting for the next poll.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                Task { @MainActor [weak self] in self?.refresh() }
            }
        }
    }

    // MARK: - Refresh

    private func refresh() {
        scriptQueue.async { [weak self] in
            let snapshot = NowPlayingScripting.fetchSnapshot()
            Task { @MainActor [weak self] in self?.apply(snapshot) }
        }
    }

    /// Runs on the main actor: publishes the snapshot and (for Spotify) kicks off
    /// artwork loading.
    private func apply(_ snapshot: NowPlayingSnapshot?) {
        guard let snapshot else { clear(); return }

        isPlaying = snapshot.isPlaying
        hasTrack = !snapshot.title.isEmpty
        title = snapshot.title.isEmpty ? "Nothing playing" : snapshot.title
        artist = snapshot.artist

        if let urlString = snapshot.artworkURL, !urlString.isEmpty {
            loadArtwork(urlString: urlString)
        } else {
            // Apple Music: no easy AppleScript artwork → fall back to app icon.
            lastArtworkURL = nil
            artwork = NSWorkspace.shared.runningApplications
                .first { $0.bundleIdentifier == snapshot.player.bundleID }?.icon
        }
    }

    private func clear() {
        title = "Nothing playing"
        artist = ""
        artwork = nil
        isPlaying = false
        hasTrack = false
        lastArtworkURL = nil
    }

    // MARK: - Artwork

    private func loadArtwork(urlString: String) {
        guard urlString != lastArtworkURL, let url = URL(string: urlString) else { return }
        lastArtworkURL = urlString
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let image = NSImage(data: data) else { return }
            Task { @MainActor [weak self] in self?.artwork = image }
        }.resume()
    }

    deinit { timer?.invalidate() }
}

// MARK: - Scripting (fully nonisolated — runs on the background scripting queue)

private enum NowPlayingScripting {

    static func isRunning(_ player: NowPlayingPlayer) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == player.bundleID }
    }

    /// Choose which player to display: a playing one wins; else any running one.
    static func pickPlayer() -> NowPlayingPlayer? {
        var pausedCandidate: NowPlayingPlayer?
        for player in [NowPlayingPlayer.spotify, .music] where isRunning(player) {
            switch state(of: player) {
            case "playing": return player
            case "paused", "stopped": if pausedCandidate == nil { pausedCandidate = player }
            default: break
            }
        }
        return pausedCandidate
    }

    static func state(of player: NowPlayingPlayer) -> String {
        runAppleScript("tell application \"\(player.appName)\" to return player state as text")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Full read of the active player. Returns nil when nothing is playing/paused.
    static func fetchSnapshot() -> NowPlayingSnapshot? {
        guard let player = pickPlayer() else { return nil }

        let script: String
        switch player {
        case .spotify:
            // Spotify exposes an artwork URL we can fetch.
            script = """
            tell application "Spotify"
                set s to player state as text
                set n to name of current track
                set a to artist of current track
                set u to artwork url of current track
                return s & "\\n" & n & "\\n" & a & "\\n" & u
            end tell
            """
        case .music:
            script = """
            tell application "Music"
                set s to player state as text
                set n to name of current track
                set a to artist of current track
                return s & "\\n" & n & "\\n" & a
            end tell
            """
        }

        guard let raw = runAppleScript(script) else { return nil }
        let parts = raw.components(separatedBy: "\n")
        guard parts.count >= 3 else { return nil }

        let st = parts[0].trimmingCharacters(in: .whitespaces)
        let trackTitle = parts[1].trimmingCharacters(in: .whitespaces)
        let trackArtist = parts[2].trimmingCharacters(in: .whitespaces)
        let artURL = (player == .spotify && parts.count >= 4)
            ? parts[3].trimmingCharacters(in: .whitespaces) : nil

        return NowPlayingSnapshot(player: player,
                                  isPlaying: st == "playing",
                                  title: trackTitle,
                                  artist: trackArtist,
                                  artworkURL: artURL)
    }

    static func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if error != nil { return nil }
        return result.stringValue
    }
}

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

import Foundation
import AppKit
import Combine

@MainActor
final class NowPlayingManager: ObservableObject {

    @Published var title: String = "Nothing playing"
    @Published var artist: String = ""
    @Published var artwork: NSImage? = nil
    @Published var isPlaying: Bool = false
    @Published var hasTrack: Bool = false

    private enum Player {
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

    private var activePlayer: Player?
    private var timer: Timer?
    private var lastArtworkURL: String?

    // MARK: - Lifecycle

    func start() {
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refresh()
    }

    // MARK: - Transport controls

    func togglePlayPause() { runControl("playpause") }
    func nextTrack()       { runControl("next track") }
    func previousTrack()   { runControl("previous track") }

    private func runControl(_ command: String) {
        guard let player = activePlayer else { return }
        _ = runAppleScript("tell application \"\(player.appName)\" to \(command)")
        // Reflect the change quickly rather than waiting for the next poll.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.refresh() }
    }

    // MARK: - Refresh

    private func refresh() {
        // Prefer a player that is actually playing; otherwise show a paused one.
        if let p = pickPlayer() {
            activePlayer = p
            apply(player: p)
        } else {
            activePlayer = nil
            clear()
        }
    }

    private func isRunning(_ player: Player) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == player.bundleID }
    }

    /// Choose which player to display: a playing one wins; else any running one.
    private func pickPlayer() -> Player? {
        var pausedCandidate: Player?
        for player in [Player.spotify, .music] where isRunning(player) {
            switch state(of: player) {
            case "playing": return player
            case "paused", "stopped": if pausedCandidate == nil { pausedCandidate = player }
            default: break
            }
        }
        return pausedCandidate
    }

    private func state(of player: Player) -> String {
        runAppleScript("tell application \"\(player.appName)\" to return player state as text")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func apply(player: Player) {
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

        guard let raw = runAppleScript(script) else { clear(); return }
        let parts = raw.components(separatedBy: "\n")
        guard parts.count >= 3 else { clear(); return }

        let st = parts[0].trimmingCharacters(in: .whitespaces)
        let trackTitle = parts[1].trimmingCharacters(in: .whitespaces)
        let trackArtist = parts[2].trimmingCharacters(in: .whitespaces)

        isPlaying = (st == "playing")
        hasTrack = !trackTitle.isEmpty
        title = trackTitle.isEmpty ? "Nothing playing" : trackTitle
        artist = trackArtist

        if player == .spotify, parts.count >= 4 {
            loadArtwork(urlString: parts[3].trimmingCharacters(in: .whitespaces))
        } else {
            // Apple Music: no easy AppleScript artwork → fall back to the app icon.
            lastArtworkURL = nil
            artwork = NSWorkspace.shared.runningApplications
                .first { $0.bundleIdentifier == player.bundleID }?.icon
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
        guard !urlString.isEmpty, urlString != lastArtworkURL,
              let url = URL(string: urlString) else { return }
        lastArtworkURL = urlString
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let image = NSImage(data: data) else { return }
            Task { @MainActor in self?.artwork = image }
        }.resume()
    }

    // MARK: - AppleScript

    private func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if error != nil { return nil }
        return result.stringValue
    }

    deinit { timer?.invalidate() }
}

//
//  UpdateChecker.swift
//  Notchly — "Check for updates"
//
//  Notchly ships via GitHub Releases and is unsigned, so it can't self-update.
//  This just asks the GitHub API for the latest release tag, compares it to the
//  bundled version, and (if newer) hands back the release page to open.
//

import Foundation
import Combine

/// The current app version. Bump this when cutting a release tag (vX.Y.Z).
enum AppInfo {
    static let version = "1.4.3"
    static let releasesURL = URL(string: "https://github.com/gronker22/Notchly/releases")!
    static let latestAPI = URL(string: "https://api.github.com/repos/gronker22/Notchly/releases/latest")!
}

@MainActor
final class UpdateChecker: ObservableObject {
    @Published private(set) var status = ""
    @Published private(set) var checking = false
    @Published private(set) var updateURL: URL?

    func check() {
        guard !checking else { return }
        checking = true
        status = "Checking…"
        updateURL = nil

        Task {
            defer { checking = false }
            do {
                var req = URLRequest(url: AppInfo.latestAPI)
                req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                req.timeoutInterval = 10
                let (data, _) = try await URLSession.shared.data(for: req)
                struct Release: Decodable { let tag_name: String; let html_url: String }
                let rel = try JSONDecoder().decode(Release.self, from: data)
                let latest = rel.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
                if Self.isNewer(latest, than: AppInfo.version) {
                    status = "Update available: v\(latest)"
                    updateURL = URL(string: rel.html_url) ?? AppInfo.releasesURL
                } else {
                    status = "You're on the latest version (v\(AppInfo.version))."
                }
            } catch {
                status = "Couldn't check right now. Try again later."
            }
        }
    }

    /// Semantic-ish compare of dotted integer versions.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

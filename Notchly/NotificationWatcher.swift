//
//  NotificationWatcher.swift
//  Notchly — mirror incoming notifications into the notch
//
//  macOS gives an app no supported way to read *other* apps' notifications.
//  The old trick — reading Notification Center's SQLite store under
//  DARWIN_USER_DIR/com.apple.notificationcenter/db2/db — no longer works: on
//  current macOS that file isn't there at all (verified on macOS 27), and even
//  where it did exist it needed Full Disk Access and broke on every schema
//  change.
//
//  So this watches the UI instead. Notification Center draws each banner as a
//  window in the `com.apple.notificationcenterui` process; with the
//  Accessibility permission we can be told when one appears and read its text.
//  That is still unofficial — Apple doesn't promise this layout — so every step
//  fails soft: no permission, no Notification Center process, or an unfamiliar
//  window shape all end in "no banners mirrored", never a crash.
//
//  Deliberately *not* enabled by default: it costs an Accessibility prompt,
//  which is the heaviest permission Notchly asks for.
//

import Foundation
import Combine
import AppKit
import ApplicationServices

@MainActor
final class NotificationWatcher: ObservableObject {

    struct Banner: Identifiable, Equatable {
        let id = UUID()
        let app: String
        let title: String
        let body: String
        let date: Date
    }

    /// Most recent banners, newest first, capped at `maxBanners`.
    @Published private(set) var banners: [Banner] = []
    /// True once we hold Accessibility *and* found Notification Center.
    @Published private(set) var active = false
    /// Set when we can't run, so the UI can explain why instead of sitting blank.
    @Published private(set) var unavailableReason: String?

    private let maxBanners = 4
    private let keepFor: TimeInterval = 600   // drop banners older than 10 min

    private var observer: AXObserver?
    private var appElement: AXUIElement?
    private var watchedPID: pid_t?
    private var launchObserver: (any NSObjectProtocol)?
    private var started = false

    // MARK: - Permission

    /// Whether Accessibility is already granted. Never prompts.
    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// Asks macOS to show the Accessibility prompt. Returns the state *now* —
    /// granting is asynchronous and requires the user to visit System Settings,
    /// so callers should re-check rather than trusting a `false` here.
    @discardableResult
    static func requestAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true

        guard Self.hasAccessibility else {
            unavailableReason = "Notchly needs Accessibility access to read notification banners."
            return
        }
        attach()

        // Notification Center can be restarted by the system; re-attach if so.
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == Self.notificationCenterBundleID else { return }
                Task { @MainActor [weak self] in self?.attach() }
            }
    }

    func stop() {
        guard started else { return }
        started = false
        detach()
        if let launchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(launchObserver)
        }
        launchObserver = nil
        banners.removeAll()
        active = false
        unavailableReason = nil
    }

    // MARK: - Attaching to Notification Center

    private static let notificationCenterBundleID = "com.apple.notificationcenterui"

    private func attach() {
        detach()

        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.notificationCenterBundleID)
            .first else {
            unavailableReason = "Notification Center isn't running."
            return
        }

        let pid = app.processIdentifier
        let element = AXUIElementCreateApplication(pid)

        var obs: AXObserver?
        let err = AXObserverCreate(pid, { _, element, _, refcon in
            guard let refcon else { return }
            let watcher = Unmanaged<NotificationWatcher>.fromOpaque(refcon).takeUnretainedValue()
            // AX callbacks arrive on the observer's run loop (main here), but the
            // compiler can't know that, so hop explicitly.
            let box = AXBox(element)
            Task { @MainActor in watcher.handleNewWindow(box.element) }
        }, &obs)

        guard err == .success, let obs else {
            unavailableReason = "Couldn't observe Notification Center."
            return
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // Banner windows show up as created windows on the NC app element.
        for notif in [kAXWindowCreatedNotification, kAXCreatedNotification] {
            AXObserverAddNotification(obs, element, notif as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           AXObserverGetRunLoopSource(obs),
                           .defaultMode)

        observer = obs
        appElement = element
        watchedPID = pid
        active = true
        unavailableReason = nil
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(),
                                  AXObserverGetRunLoopSource(observer),
                                  .defaultMode)
        }
        observer = nil
        appElement = nil
        watchedPID = nil
        active = false
    }

    // MARK: - Reading a banner

    fileprivate func handleNewWindow(_ window: AXUIElement) {
        // A banner is a window holding a few AXStaticText descendants: usually
        // app name, title, then body. Layout isn't documented, so take the
        // strings in order and assign them defensively.
        var texts: [String] = []
        collectStaticText(window, into: &texts, depth: 0)

        let cleaned = texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }

        let app: String
        let title: String
        let body: String
        switch cleaned.count {
        case 1:
            app = ""; title = cleaned[0]; body = ""
        case 2:
            app = cleaned[0]; title = cleaned[1]; body = ""
        default:
            app = cleaned[0]; title = cleaned[1]
            body = cleaned.dropFirst(2).joined(separator: " ")
        }

        let banner = Banner(app: app, title: title, body: body, date: Date())

        // Notification Center redraws banners, so the same text can arrive more
        // than once within a second or two. Collapse those.
        if let last = banners.first,
           last.title == banner.title, last.body == banner.body,
           Date().timeIntervalSince(last.date) < 3 {
            return
        }

        banners.insert(banner, at: 0)
        prune()
    }

    private func collectStaticText(_ element: AXUIElement, into out: inout [String], depth: Int) {
        guard depth < 8, out.count < 8 else { return }

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        if let role = roleRef as? String, role == kAXStaticTextRole {
            var valueRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
            if let s = valueRef as? String { out.append(s) }
        }

        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        guard let children = childrenRef as? [AXUIElement] else { return }
        for child in children {
            collectStaticText(child, into: &out, depth: depth + 1)
        }
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-keepFor)
        banners.removeAll { $0.date < cutoff }
        if banners.count > maxBanners {
            banners = Array(banners.prefix(maxBanners))
        }
    }

    func clear() { banners.removeAll() }
}

/// AXUIElement is a CFType and isn't marked Sendable; boxing it keeps the hop to
/// the main actor explicit rather than silently unchecked at each call site.
private struct AXBox: @unchecked Sendable {
    let element: AXUIElement
    init(_ element: AXUIElement) { self.element = element }
}

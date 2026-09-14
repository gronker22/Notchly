//
//  CalendarManager.swift
//  Notchly — Phase 3: Calendar event
//
//  EventKit. Requests calendar access on first launch, then surfaces the next
//  upcoming event within the next 24 hours: a truncated title + a countdown
//  string ("in 12m" / "in 2h"). Exposes `isImminent` (< 5 min away) so the
//  collapsed pill can pulse.
//

import Foundation
import EventKit
import Combine

@MainActor
final class CalendarManager: ObservableObject {

    @Published private(set) var nextEventTitle: String?   // truncated to 24 chars
    @Published private(set) var countdownString: String?  // "in 12m" / "in 2h"
    @Published private(set) var isImminent: Bool = false  // next event < 5 min away
    @Published private(set) var hasEvent: Bool = false
    @Published private(set) var meetingURL: URL?          // Zoom/Meet/Teams/… if detected

    private let store = EKEventStore()
    private var nextEventDate: Date?
    private var refreshTimer: Timer?

    // MARK: - Lifecycle

    func start() {
        requestAccess()

        // Re-evaluate the countdown / imminence every 15s.
        let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t

        // Refetch when the user changes their calendars.
        NotificationCenter.default.addObserver(
            self, selector: #selector(storeChanged),
            name: .EKEventStoreChanged, object: store
        )
    }

    @objc private func storeChanged() { fetchNextEvent() }

    private func requestAccess() {
        let handler: (Bool, Error?) -> Void = { [weak self] granted, _ in
            guard granted else { return }
            Task { @MainActor in self?.fetchNextEvent() }
        }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { granted, error in handler(granted, error) }
        } else {
            store.requestAccess(to: .event) { granted, error in handler(granted, error) }
        }
    }

    // MARK: - Fetch

    private func fetchNextEvent() {
        let now = Date()
        let end = now.addingTimeInterval(24 * 60 * 60)
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)

        let next = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.startDate > now }
            .sorted { $0.startDate < $1.startDate }
            .first

        if let event = next {
            nextEventDate = event.startDate
            nextEventTitle = truncate(event.title ?? "Untitled", to: 24)
            hasEvent = true
            meetingURL = Self.detectMeetingURL(in: event)
        } else {
            nextEventDate = nil
            nextEventTitle = nil
            hasEvent = false
            meetingURL = nil
        }
        refresh()
    }

    // MARK: - Meeting link detection

    private static let meetingHosts = [
        "zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com",
        "webex.com", "whereby.com", "meet.jit.si", "chime.aws"
    ]

    private static func isMeeting(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return meetingHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Look for a video-call link in the event's URL, then its notes/location.
    private static func detectMeetingURL(in event: EKEvent) -> URL? {
        if let u = event.url, isMeeting(u) { return u }
        let text = [event.notes, event.location].compactMap { $0 }.joined(separator: "\n")
        guard !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return nil }
        var found: URL?
        detector.enumerateMatches(in: text, options: [], range: NSRange(text.startIndex..., in: text)) { match, _, stop in
            if let u = match?.url, isMeeting(u) { found = u; stop.pointee = true }
        }
        return found
    }

    // MARK: - Countdown

    private func refresh() {
        guard let date = nextEventDate else {
            countdownString = nil
            isImminent = false
            // Drop stale events past their start time.
            if hasEvent { fetchNextEvent() }
            return
        }

        let interval = date.timeIntervalSinceNow
        if interval <= 0 {
            // Event started — move on to the next one.
            fetchNextEvent()
            return
        }

        countdownString = countdown(for: interval)
        isImminent = interval < 5 * 60
    }

    // MARK: - Formatting

    private func countdown(for interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        if minutes < 60 {
            return "in \(max(1, minutes))m"
        }
        let hours = Int((interval / 3600).rounded())
        return "in \(hours)h"
    }

    private func truncate(_ s: String, to n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n - 1)) + "…"
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}

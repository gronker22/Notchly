//
//  PomodoroManager.swift
//  Notchly — Pomodoro timer
//
//  Adjustable work / break durations. Start / pause / reset. Publishes the
//  fractional progress (0...1) for the collapsed ring and a "MM:SS" string for
//  the in-pill label. Fires a local notification when a phase hits 0.
//

import Foundation
import Combine
import UserNotifications

@MainActor
final class PomodoroManager: ObservableObject {

    enum Phase {
        case work
        case shortBreak
        var title: String { self == .work ? "Focus" : "Break" }
    }

    @Published private(set) var phase: Phase = .work
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var tickToken: Int = 0

    /// Adjustable durations (minutes), persisted.
    @Published private(set) var workMinutes: Int {
        didSet { defaults.set(workMinutes, forKey: Keys.work) }
    }
    @Published private(set) var breakMinutes: Int {
        didSet { defaults.set(breakMinutes, forKey: Keys.breakKey) }
    }

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let work = "notchly.pomodoro.work"
        static let breakKey = "notchly.pomodoro.break"
    }

    private var timer: Timer?
    private var elapsedBeforePause: TimeInterval = 0
    private var runStart: Date?
    private var notificationsRequested = false

    init() {
        let w = defaults.integer(forKey: Keys.work)
        let b = defaults.integer(forKey: Keys.breakKey)
        workMinutes = w > 0 ? w : 25
        breakMinutes = b > 0 ? b : 5
    }

    // MARK: - Durations

    private func duration(for phase: Phase) -> TimeInterval {
        switch phase {
        case .work:       return TimeInterval(workMinutes) * 60
        case .shortBreak: return TimeInterval(breakMinutes) * 60
        }
    }

    private var currentDuration: TimeInterval { duration(for: phase) }

    /// Step the current phase's length up/down along the clean sequence
    /// 1, 5, 10, 15, 20, … (only while not running). The sign of `delta` chooses
    /// direction; the magnitude is ignored so it always snaps to round values.
    func adjustMinutes(by delta: Int) {
        guard !isRunning else { return }
        let up = delta > 0
        switch phase {
        case .work:       workMinutes = min(120, stepped(workMinutes, up: up))
        case .shortBreak: breakMinutes = min(60, stepped(breakMinutes, up: up))
        }
        elapsedBeforePause = 0   // restart the phase from its new length
        tickToken &+= 1
    }

    /// Next/previous value in the sequence 1, 5, 10, 15, 20, …
    private func stepped(_ value: Int, up: Bool) -> Int {
        if up {
            return value < 5 ? 5 : (value / 5) * 5 + 5
        } else {
            if value <= 5 { return 1 }
            return value % 5 == 0 ? value - 5 : (value / 5) * 5
        }
    }

    // MARK: - Derived state

    private var elapsed: TimeInterval {
        let running = isRunning ? Date().timeIntervalSince(runStart ?? Date()) : 0
        return min(currentDuration, elapsedBeforePause + running)
    }

    var remaining: TimeInterval { max(0, currentDuration - elapsed) }

    var progress: Double {
        let total = currentDuration
        guard total > 0 else { return 0 }
        return min(1, max(0, elapsed / total))
    }

    var remainingString: String {
        let secs = max(0, Int(remaining.rounded()))
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }

    // MARK: - Controls

    func startPause() { isRunning ? pause() : start() }

    func start() {
        guard !isRunning else { return }
        requestNotificationsIfNeeded()
        isRunning = true
        runStart = Date()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func pause() {
        guard isRunning else { return }
        elapsedBeforePause = elapsed
        isRunning = false
        runStart = nil
        timer?.invalidate()
        timer = nil
    }

    func reset() {
        pause()
        phase = .work
        elapsedBeforePause = 0
    }

    // MARK: - Tick

    private func tick() {
        if remaining <= 0 {
            advancePhase()
        }
        tickToken &+= 1
    }

    private func advancePhase() {
        // Notify about the phase that just finished, then roll into the next.
        notifyCompletion(of: phase)
        phase = (phase == .work) ? .shortBreak : .work
        elapsedBeforePause = 0
        runStart = Date()
    }

    // MARK: - Notifications

    private func requestNotificationsIfNeeded() {
        guard !notificationsRequested else { return }
        notificationsRequested = true
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notifyCompletion(of finished: Phase) {
        let content = UNMutableNotificationContent()
        if finished == .work {
            content.title = "Focus session complete"
            content.body = "Time for a \(breakMinutes)-minute break."
        } else {
            content.title = "Break over"
            content.body = "Back to a \(workMinutes)-minute focus session."
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil   // deliver immediately
        )
        UNUserNotificationCenter.current().add(request)
    }
}

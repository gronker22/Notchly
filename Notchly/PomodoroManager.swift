//
//  PomodoroManager.swift
//  Notchly — Phase 3: Pomodoro timer
//
//  25 min work / 5 min break cycle. Start / pause / reset. Publishes the
//  fractional progress (0...1) for the collapsed ring overlay and a "MM:SS"
//  string for the tiny in-pill label.
//

import Foundation
import Combine

@MainActor
final class PomodoroManager: ObservableObject {

    enum Phase {
        case work
        case shortBreak

        var duration: TimeInterval {
            switch self {
            case .work: return 25 * 60
            case .shortBreak: return 5 * 60
            }
        }
    }

    @Published private(set) var phase: Phase = .work
    @Published private(set) var isRunning: Bool = false
    /// Bumped every second so the "MM:SS" label refreshes. The ring reads the
    /// continuous `progress` getter (via TimelineView) for sub-second smoothness.
    @Published private(set) var tickToken: Int = 0

    private var timer: Timer?

    // Continuous-clock bookkeeping so progress is smooth, not stepped.
    private var elapsedBeforePause: TimeInterval = 0
    private var runStart: Date?

    // MARK: - Derived state (read by the UI)

    /// Total elapsed in the current phase, computed live.
    private var elapsed: TimeInterval {
        let running = isRunning ? Date().timeIntervalSince(runStart ?? Date()) : 0
        return min(phase.duration, elapsedBeforePause + running)
    }

    /// Seconds left in the current phase.
    var remaining: TimeInterval { max(0, phase.duration - elapsed) }

    /// 0 at the start of a phase → 1 when it completes. Drives the ring.
    var progress: Double {
        let total = phase.duration
        guard total > 0 else { return 0 }
        return min(1, max(0, elapsed / total))
    }

    /// "18:42" — only meant to be shown while running.
    var remainingString: String {
        let secs = max(0, Int(remaining.rounded()))
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }

    // MARK: - Controls

    func startPause() {
        isRunning ? pause() : start()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        runStart = Date()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // .common keeps it firing while the user interacts with menus/UI.
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

    // MARK: - Tick (phase rollover + label refresh)

    private func tick() {
        if remaining <= 0 {
            advancePhase()
        }
        tickToken &+= 1   // nudges SwiftUI to refresh the "MM:SS" label
    }

    private func advancePhase() {
        // Auto-roll into the next phase and keep running (classic Pomodoro feel).
        phase = (phase == .work) ? .shortBreak : .work
        elapsedBeforePause = 0
        runStart = Date()
    }
}

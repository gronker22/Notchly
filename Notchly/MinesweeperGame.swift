//
//  MinesweeperGame.swift
//  Notchly — Minesweeper
//
//  Classic Minesweeper: first tap is always safe (mines are placed afterwards,
//  avoiding the tapped cell and its neighbours), zero-cells flood-reveal, and a
//  per-difficulty best time is kept locally. Flagging is via a flag-mode toggle
//  or a long-press so it works cleanly on a trackpad.
//

import Foundation
import Combine

@MainActor
final class MinesweeperGame: ObservableObject {

    enum Difficulty: String, CaseIterable, Identifiable {
        case beginner, intermediate, expert
        var id: String { rawValue }
        var size: Int { self == .beginner ? 9 : self == .intermediate ? 12 : 16 }
        var mines: Int { self == .beginner ? 10 : self == .intermediate ? 24 : 40 }
        var label: String { rawValue.capitalized }
    }

    enum Status { case ready, playing, won, lost }

    struct Cell: Identifiable {
        let id: Int
        var isMine = false
        var adjacent = 0
        var revealed = false
        var flagged = false
    }

    @Published private(set) var cells: [Cell] = []
    @Published private(set) var status: Status = .ready
    @Published private(set) var flagsUsed = 0
    @Published private(set) var elapsed = 0
    @Published var difficulty: Difficulty { didSet { if difficulty != oldValue { reset() } } }
    @Published private(set) var bestTime: Int = 0   // for current difficulty, 0 = none

    var cols: Int { difficulty.size }
    var rows: Int { difficulty.size }
    var minesRemaining: Int { max(0, difficulty.mines - flagsUsed) }

    private var minesPlaced = false
    private var timer: Timer?
    private let defaults = UserDefaults.standard
    private func bestKey(_ d: Difficulty) -> String { "notchly.mines.best.\(d.rawValue)" }

    init() {
        difficulty = Difficulty(rawValue: UserDefaults.standard.string(forKey: "notchly.mines.diff") ?? "beginner") ?? .beginner
        reset()
    }

    // MARK: - New game

    func reset() {
        defaults.set(difficulty.rawValue, forKey: "notchly.mines.diff")
        timer?.invalidate(); timer = nil
        minesPlaced = false
        status = .ready
        flagsUsed = 0
        elapsed = 0
        bestTime = defaults.integer(forKey: bestKey(difficulty))
        cells = (0..<(cols * rows)).map { Cell(id: $0) }
    }

    // MARK: - Interaction

    func tap(_ index: Int, flagMode: Bool) {
        if flagMode { toggleFlag(index) } else { reveal(index) }
    }

    func toggleFlag(_ index: Int) {
        guard status == .ready || status == .playing else { return }
        guard !cells[index].revealed else { return }
        cells[index].flagged.toggle()
        flagsUsed += cells[index].flagged ? 1 : -1
    }

    func reveal(_ index: Int) {
        guard status == .ready || status == .playing else { return }
        guard !cells[index].revealed, !cells[index].flagged else { return }

        if !minesPlaced { placeMines(safe: index); startTimer(); status = .playing }

        if cells[index].isMine {
            cells[index].revealed = true
            lose()
            return
        }
        floodReveal(from: index)
        checkWin()
    }

    // MARK: - Board setup

    private func placeMines(safe: Int) {
        let safeZone = Set(neighbors(of: safe) + [safe])
        var candidates = (0..<cells.count).filter { !safeZone.contains($0) }
        candidates.shuffle()
        for i in candidates.prefix(difficulty.mines) { cells[i].isMine = true }

        for i in 0..<cells.count where !cells[i].isMine {
            cells[i].adjacent = neighbors(of: i).filter { cells[$0].isMine }.count
        }
        minesPlaced = true
    }

    private func neighbors(of index: Int) -> [Int] {
        let r = index / cols, c = index % cols
        var result: [Int] = []
        for dr in -1...1 {
            for dc in -1...1 where !(dr == 0 && dc == 0) {
                let nr = r + dr, nc = c + dc
                if nr >= 0, nr < rows, nc >= 0, nc < cols { result.append(nr * cols + nc) }
            }
        }
        return result
    }

    /// Iterative flood-fill: reveal the cell; if it has no adjacent mines, reveal
    /// its neighbours too, cascading through the empty region.
    private func floodReveal(from start: Int) {
        var stack = [start]
        while let idx = stack.popLast() {
            guard !cells[idx].revealed, !cells[idx].flagged, !cells[idx].isMine else { continue }
            cells[idx].revealed = true
            if cells[idx].adjacent == 0 {
                stack.append(contentsOf: neighbors(of: idx).filter { !cells[$0].revealed })
            }
        }
    }

    // MARK: - End states

    private func checkWin() {
        let unrevealedSafe = cells.contains { !$0.isMine && !$0.revealed }
        if !unrevealedSafe { win() }
    }

    private func win() {
        status = .won
        timer?.invalidate(); timer = nil
        // Flag all mines for a tidy finish.
        for i in 0..<cells.count where cells[i].isMine { cells[i].flagged = true }
        flagsUsed = difficulty.mines
        if bestTime == 0 || elapsed < bestTime {
            bestTime = elapsed
            defaults.set(bestTime, forKey: bestKey(difficulty))
        }
    }

    private func lose() {
        status = .lost
        timer?.invalidate(); timer = nil
        for i in 0..<cells.count where cells[i].isMine { cells[i].revealed = true }
    }

    // MARK: - Timer

    private func startTimer() {
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.status == .playing else { return }
                if self.elapsed < 999 { self.elapsed += 1 }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    deinit { timer?.invalidate() }
}

//
//  ClipboardManager.swift
//  Notchly — Phase 4: Clipboard history
//
//  Polls NSPasteboard.changeCount every 0.5s and keeps the last 5 copied
//  strings (images are ignored for now). Tapping an item writes it back to the
//  pasteboard and flashes "Copied!".
//

import AppKit
import Combine

@MainActor
final class ClipboardManager: ObservableObject {

    /// Most-recent-first, max 5.
    @Published private(set) var items: [String] = []
    /// Index of the item that just flashed "Copied!", if any.
    @Published private(set) var flashIndex: Int?

    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    private var timer: Timer?
    private var flashWorkItem: DispatchWorkItem?

    // Set true while WE write to the pasteboard, so our own write doesn't get
    // re-ingested as a new "copied" entry.
    private var suppressNextCapture = false

    private let maxItems = 5

    init() {
        lastChangeCount = pasteboard.changeCount
    }

    // MARK: - Lifecycle

    func start() {
        captureCurrent()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - Polling

    private func poll() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        if suppressNextCapture {
            suppressNextCapture = false
            return
        }
        captureCurrent()
    }

    private func captureCurrent() {
        guard let string = pasteboard.string(forType: .string),
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // De-dupe: move an existing match to the front instead of duplicating.
        items.removeAll { $0 == string }
        items.insert(string, at: 0)
        if items.count > maxItems {
            items = Array(items.prefix(maxItems))
        }
    }

    // MARK: - Write-back

    func copy(_ item: String, at index: Int) {
        suppressNextCapture = true
        pasteboard.clearContents()
        pasteboard.setString(item, forType: .string)
        lastChangeCount = pasteboard.changeCount

        // Move it to the front and flash.
        items.removeAll { $0 == item }
        items.insert(item, at: 0)

        flashIndex = 0
        flashWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flashIndex = nil }
        flashWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    deinit { timer?.invalidate() }
}

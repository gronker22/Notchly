//
//  FileShelf.swift
//  Notchly — drag files onto the notch, park them, drag them back out.
//
//  Solves the everyday "I need this file over there" shuffle: drop files on the
//  notch from any app or Finder window, switch Space / app / window, then drag
//  them out again. Paths are remembered across launches; entries whose file has
//  since moved or been deleted are dropped on load.
//

import Foundation
import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class FileShelf: ObservableObject {
    static let shared = FileShelf()

    struct Item: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        var name: String { url.lastPathComponent }
        static func == (a: Item, b: Item) -> Bool { a.url == b.url }
    }

    @Published private(set) var items: [Item] = []

    private let maxItems = 12
    private let defaults = UserDefaults.standard
    private let key = "notchly.shelf.paths"

    private init() {
        let saved = defaults.stringArray(forKey: key) ?? []
        items = saved
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { Item(url: $0) }
    }

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }

    func add(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        for url in urls.reversed() where !items.contains(where: { $0.url == url }) {
            items.insert(Item(url: url), at: 0)
        }
        if items.count > maxItems { items = Array(items.prefix(maxItems)) }
        persist()
    }

    func remove(_ item: Item) {
        items.removeAll { $0.id == item.id }
        persist()
    }

    func clear() {
        items.removeAll()
        persist()
    }

    /// Reveal in Finder.
    func reveal(_ item: Item) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func icon(for item: Item) -> NSImage {
        NSWorkspace.shared.icon(forFile: item.url.path)
    }

    private func persist() {
        defaults.set(items.map { $0.url.path }, forKey: key)
    }
}

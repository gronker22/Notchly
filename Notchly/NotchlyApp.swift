//
//  NotchlyApp.swift
//  Notchly — Phase 1: Window foundation + bubble physics shape
//
//  Entry point. Notchly has NO main window and NO Dock icon (LSUIElement = YES).
//  All UI lives in a borderless NSPanel managed by NotchWindowController.
//

import SwiftUI
import AppKit
import os

@main
struct NotchlyApp: App {
    // We drive everything through an AppDelegate because the visible surface is
    // an NSPanel, not a SwiftUI WindowGroup.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // No Settings/WindowGroup scene is shown. `Settings` gives SwiftUI a
        // valid (but empty) scene without creating a visible window.
        Settings {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchController: NotchWindowController?
    private var statusItem: NSStatusItem?

    private let shelfService = ShelfService()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Services menu entry: right-click a file in Finder -> Services ->
        // "Add to Notchly Shelf". This is the one route that involves no
        // dragging at all, so nothing can intercept it.
        NSApp.servicesProvider = shelfService
        NSUpdateDynamicServices()
        dropLog.log("services provider registered")
        // Single-instance guard: if another Notchly is already running (e.g. an
        // installed copy plus a debug build — both share the bundle id), quit
        // immediately so we don't draw a second, overlapping notch bubble.
        if let bundleID = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID)
                .filter { $0 != .current }
            if !others.isEmpty {
                NSApp.terminate(nil)
                return
            }
        }

        // Accessory app: no Dock icon, no menu bar takeover.
        NSApp.setActivationPolicy(.accessory)

        // Always-visible off switch: a small menu bar icon whose menu can quit
        // Notchly. (There's also a "Quit Notchly" button in Settings.) Without
        // this an accessory app can only be quit via Activity Monitor.
        setupStatusItem()

        notchController = NotchWindowController()
        notchController?.show()

        // First-run onboarding (once).
        if !NotchSettings.shared.hasCompletedOnboarding {
            OnboardingWindowPresenter.show {
                NotchSettings.shared.hasCompletedOnboarding = true
            }
        }


        // Re-center if the screen configuration changes (display added/removed,
        // resolution change, notebook lid open/close, etc.).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func screenParametersChanged() {
        notchController?.repositionForCurrentScreen()
    }

    // MARK: - Menu bar off switch

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            // A little notch-shaped glyph; fall back to a text mark if the symbol
            // isn't available on this OS.
            let image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled",
                                accessibilityDescription: "Notchly")
            image?.isTemplate = true
            button.image = image
            if image == nil { button.title = "◗" }
            button.toolTip = "Notchly — drop files here to add them to the shelf"

            // Drag workaround. Dropping onto the notch itself competes with
            // Mission Control, which the window server triggers for gestures
            // near the top-centre of the screen and which then covers every
            // window before any app sees the drag. The menu bar icon is a
            // small, explicit target that AppKit routes drags to directly, so
            // it isn't affected.
            //
            // NSStatusBarButton doesn't handle drops itself, so a transparent
            // drop view is layered over it.
            //
            // Pinned with constraints, not `button.bounds` + autoresizing: at
            // this point the status item hasn't been laid out, so its button is
            // still zero-sized. A zero-sized view can never be a drag
            // destination, which is why dropping on the icon did nothing.
            let dropView = StatusItemDropView(frame: .zero)
            dropView.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(dropView)
            NSLayoutConstraint.activate([
                dropView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                dropView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                dropView.topAnchor.constraint(equalTo: button.topAnchor),
                dropView.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            ])
            dropLog.log("status item drop view attached; button bounds=\(NSStringFromRect(button.bounds), privacy: .public)")
        }

        let menu = NSMenu()
        let header = NSMenuItem(title: "Notchly is running", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(withTitle: "Hover the notch for settings", action: nil, keyEquivalent: "")
            .isEnabled = false
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Notchly", action: #selector(quitNotchly), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    @objc private func quitNotchly() {
        NSApp.terminate(nil)
    }
}

// MARK: - Menu bar drop target

/// Transparent view over the status item's button that accepts file drops and
/// parks them on the shelf. Clicks pass straight through to the button beneath,
/// so the menu still opens normally.
final class StatusItemDropView: NSView {

    private var lit = false { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL,
                                 NSPasteboard.PasteboardType("NSFilenamesPboardType")])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    // No hitTest override: AppKit resolves drag destinations through hitTest,
    // so returning nil would stop drops reaching this view. Clicks are instead
    // handed back to the status item button so its menu still opens.
    override func mouseDown(with event: NSEvent) {
        superview?.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        superview?.rightMouseDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard lit else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 3),
                     xRadius: 5, yRadius: 5).fill()
    }

    private func urls(_ sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let found = urls(sender)
        dropLog.log("status item draggingEntered urls=\(found.count)")
        guard !found.isEmpty else { return [] }
        lit = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        lit = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let found = urls(sender)
        lit = false
        dropLog.log("status item performDragOperation urls=\(found.count)")
        guard !found.isEmpty else { return false }
        Task { @MainActor in
            FileShelf.shared.add(found)
        }
        return true
    }
}

// MARK: - Services provider

/// Backs the "Add to Notchly Shelf" entry in the Services menu.
final class ShelfService: NSObject {
    @objc func addToShelf(_ pboard: NSPasteboard,
                          userData: String?,
                          error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        dropLog.log("services addToShelf: \(urls.count) url(s)")
        guard !urls.isEmpty else {
            error.pointee = "No files were provided." as NSString
            return
        }
        Task { @MainActor in FileShelf.shared.add(urls) }
    }
}

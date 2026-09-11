//
//  NotchlyApp.swift
//  Notchly — Phase 1: Window foundation + bubble physics shape
//
//  Entry point. Notchly has NO main window and NO Dock icon (LSUIElement = YES).
//  All UI lives in a borderless NSPanel managed by NotchWindowController.
//

import SwiftUI

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

    func applicationDidFinishLaunching(_ notification: Notification) {
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

        // PHASE 6: prompt for Accessibility up front so window docking works on
        // the first drop (no-op if already granted).
        WindowDockManager.ensureTrusted()

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
            button.toolTip = "Notchly"
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

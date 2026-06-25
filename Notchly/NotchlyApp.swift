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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessory app: no Dock icon, no menu bar takeover.
        NSApp.setActivationPolicy(.accessory)

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
}

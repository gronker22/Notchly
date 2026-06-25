//
//  WindowDockManager.swift
//  Notchly — Phase 6: Drag tabs into the island to dock windows
//
//  Snaps the frontmost window to the left or right half of its screen using the
//  Accessibility API (AXUIElement). Used when the user drags a browser tab (or
//  any drag) onto the notch island and drops it on a half-screen zone.
//
//  Requires the Accessibility permission (System Settings → Privacy & Security →
//  Accessibility). `ensureTrusted()` prompts on first use.
//
//  Coordinate note: AppKit screen frames are bottom-left origin (y up); the AX
//  API uses top-left origin relative to the PRIMARY display (y down). We convert
//  between them in `setFrame`.
//

import AppKit
import ApplicationServices

enum WindowDockManager {

    enum Half { case left, right }

    /// Prompts for / checks Accessibility trust. Returns true if granted.
    @discardableResult
    static func ensureTrusted() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Docks the focused window of the frontmost (non-Notchly) app to a half.
    @discardableResult
    static func dock(to half: Half) -> Bool {
        guard ensureTrusted() else { return false }
        guard let app = frontmostExternalApp() else { return false }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        var windowRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &windowRef
        )
        guard status == .success, let windowRef else { return false }
        let window = windowRef as! AXUIElement

        let screen = targetScreen()
        let rect = frame(for: half, on: screen)
        setFrame(window, to: rect)
        return true
    }

    // MARK: - Target selection

    private static func frontmostExternalApp() -> NSRunningApplication? {
        let workspace = NSWorkspace.shared
        if let front = workspace.frontmostApplication,
           front.processIdentifier != getpid() {
            return front
        }
        // Fallback: the app that currently owns the menu bar.
        if let owner = workspace.menuBarOwningApplication,
           owner.processIdentifier != getpid() {
            return owner
        }
        return nil
    }

    /// The screen under the cursor (where the drop happened), else main.
    private static func targetScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    // MARK: - Geometry

    /// Half-screen frame in AppKit coordinates (respects menu bar & Dock).
    private static func frame(for half: Half, on screen: NSScreen) -> CGRect {
        let vf = screen.visibleFrame
        let halfWidth = vf.width / 2
        switch half {
        case .left:
            return CGRect(x: vf.minX, y: vf.minY, width: halfWidth, height: vf.height)
        case .right:
            return CGRect(x: vf.minX + halfWidth, y: vf.minY, width: halfWidth, height: vf.height)
        }
    }

    private static func setFrame(_ window: AXUIElement, to appKitRect: CGRect) {
        // Primary display = the one whose origin is (0,0). AX is flipped relative
        // to its top edge.
        let primaryHeight = (NSScreen.screens.first { $0.frame.origin == .zero }
            ?? NSScreen.main ?? NSScreen.screens[0]).frame.height

        var position = CGPoint(
            x: appKitRect.minX,
            y: primaryHeight - appKitRect.maxY   // flip y to top-left origin
        )
        var size = CGSize(width: appKitRect.width, height: appKitRect.height)

        // Position first, then size (some apps clamp size to the current screen).
        if let posValue = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
        }
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        }
    }
}

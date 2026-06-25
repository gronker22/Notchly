//
//  NotchGeometry.swift
//  Notchly — Phase 1
//
//  Single source of truth for where the physical notch is and how big our
//  bubble should be. Every future phase reads notch width/height/position
//  from here so nothing has to re-derive the geometry.
//
//  Detection strategy:
//  - On notched MacBooks (macOS 12+), `NSScreen.safeAreaInsets.top` is the
//    height of the notch region, and `auxiliaryTopLeftArea` /
//    `auxiliaryTopRightArea` (macOS 12+) bound the usable areas beside it.
//  - We derive the notch *width* from the gap between those auxiliary areas,
//    falling back to a sensible default when the screen has no notch (e.g.
//    external display) so Notchly still renders a pill at the top-center.
//

import AppKit

struct NotchGeometry {

    /// The screen we are anchored to (the one with the notch / the main screen).
    let screen: NSScreen

    /// Physical notch height in points (0 on non-notched displays).
    let notchHeight: CGFloat

    /// Physical notch width in points (estimated on non-notched displays).
    let notchWidth: CGFloat

    /// True when this display actually has a hardware notch.
    let hasHardwareNotch: Bool

    // MARK: - Collapsed pill sizing (Phase 1 spec)

    /// Collapsed bubble width (~200pt), at least as wide as the real notch.
    var collapsedWidth: CGFloat { max(200, notchWidth) }
    /// Collapsed bubble height. We extend a small strip BELOW the physical notch
    /// so collapsed content (e.g. the running Pomodoro countdown) renders on live
    /// screen instead of being hidden in/behind the notch cutout.
    var collapsedHeight: CGFloat { max(36, notchHeight) + 16 }

    /// The strip below the notch where collapsed content is drawn.
    var collapsedContentInset: CGFloat { max(36, notchHeight) }

    // MARK: - Expanded bubble sizing (Phase 1 spec)

    /// Expanded bubble width (~480pt).
    let expandedWidth: CGFloat = 480
    /// Maximum expanded bubble height (the panel container). The bubble itself
    /// sizes to its content up to this cap. Raised to fit the sports section.
    let expandedHeight: CGFloat = 520

    // MARK: - Construction

    /// Builds geometry for the best screen (main screen / notched screen).
    static func current() -> NotchGeometry {
        let screen = preferredScreen()
        return NotchGeometry(screen: screen)
    }

    init(screen: NSScreen) {
        self.screen = screen

        // Delegate raw detection to NotchDetector (single low-level source).
        if let result = NotchDetector.detect(on: screen) {
            self.hasHardwareNotch = true
            self.notchHeight = result.height
            self.notchWidth = result.width
        } else {
            // No hardware notch: default pill, no height.
            self.hasHardwareNotch = false
            self.notchHeight = 0
            self.notchWidth = 200
        }
    }

    // MARK: - Window placement

    /// The panel is always sized to the *expanded* footprint so the bubble can
    /// grow without resizing the window. We center it horizontally and pin it
    /// flush to the very top of the screen.
    ///
    /// Returned in bottom-left-origin screen coordinates (AppKit convention).
    var panelFrame: NSRect {
        let f = screen.frame
        let x = f.midX - (expandedWidth / 2)
        // f.maxY is the physical top edge of the screen. The panel hangs down
        // from there by `expandedHeight`.
        let y = f.maxY - expandedHeight
        return NSRect(x: x, y: y, width: expandedWidth, height: expandedHeight)
    }

    // MARK: - Helpers

    private static func preferredScreen() -> NSScreen {
        NotchDetector.preferredScreen()
    }
}

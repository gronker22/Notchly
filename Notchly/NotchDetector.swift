//
//  NotchDetector.swift
//  Notchly — Phase 5
//
//  Low-level notch geometry detection. Reads a screen's frame + safeAreaInsets
//  (and the macOS 12+ auxiliary top areas) to locate the physical notch and
//  return its bounds. NotchGeometry builds on top of this; future phases can
//  call NotchDetector directly for the raw rect.
//
//  All rects are in AppKit screen coordinates (bottom-left origin).
//

import AppKit

enum NotchDetector {

    /// A screen's notch description, or `nil` if it has no hardware notch.
    struct Result {
        let screen: NSScreen
        /// Notch bounds in screen coordinates (the black region at top-center).
        let notchRect: CGRect
        var width: CGFloat { notchRect.width }
        var height: CGFloat { notchRect.height }
    }

    /// True if the screen reports a top safe-area inset (i.e. it has a notch).
    static func hasNotch(_ screen: NSScreen) -> Bool {
        screen.safeAreaInsets.top > 0
    }

    /// The screen we should anchor to: a notched screen if one exists, else main.
    static func preferredScreen() -> NSScreen {
        if let notched = NSScreen.screens.first(where: { hasNotch($0) }) {
            return notched
        }
        return NSScreen.main ?? NSScreen.screens.first!
    }

    /// Detect the notch on a specific screen.
    static func detect(on screen: NSScreen) -> Result? {
        let safeTop = screen.safeAreaInsets.top
        guard safeTop > 0 else { return nil }

        let frame = screen.frame   // physical, bottom-left origin

        // Notch width = full width minus the two usable auxiliary areas that
        // flank it. Fall back to a typical width if the areas aren't reported.
        let width: CGFloat
        if let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            width = max(120, frame.width - left.width - right.width)
        } else {
            width = 200
        }

        let rect = CGRect(
            x: frame.midX - width / 2,
            y: frame.maxY - safeTop,   // notch hangs down from the top edge
            width: width,
            height: safeTop
        )
        return Result(screen: screen, notchRect: rect)
    }

    /// Convenience: detect on the preferred screen.
    static func detect() -> Result? {
        detect(on: preferredScreen())
    }
}

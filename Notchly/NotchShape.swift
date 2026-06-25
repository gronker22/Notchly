//
//  NotchShape.swift
//  Notchly — Phase 1
//
//  A custom Shape that draws the bubble using cubic bezier curves so the edges
//  "breathe" outward like a liquid blob instead of doing a plain frame/scale
//  animation. The shape is anchored to the TOP edge (flush with the screen)
//  and grows DOWNWARD.
//
//  Animatable parameters:
//    - width / height : current bubble size (spring-driven)
//    - bottomLag      : 0...1, how far the bottom corners "trail" the rest of
//                       the blob. Driven by a slightly softer spring than size,
//                       which is what gives the surface-tension / lag feel.
//
//  All three are exposed through `animatableData` so SwiftUI interpolates the
//  PATH itself (true morphing), not just the frame.
//

import SwiftUI

struct NotchShape: Shape {
    /// Current rendered width of the bubble.
    var width: CGFloat
    /// Current rendered height of the bubble.
    var height: CGFloat
    /// 0 = bottom fully "caught up", 1 = bottom corners lagging / bulging.
    var bottomLag: CGFloat

    // Interpolate width, height, and lag simultaneously.
    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(width, AnimatablePair(height, bottomLag)) }
        set {
            width = newValue.first
            height = newValue.second.first
            bottomLag = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()

        // Center the bubble horizontally within the (fixed, expanded) rect and
        // pin it to the top edge.
        let cx = rect.midX
        let top = rect.minY
        let halfW = width / 2
        let left = cx - halfW
        let right = cx + halfW
        let bottom = top + height

        // Corner radius tuned so the collapsed pill reads as a rounded notch and
        // the expanded blob reads as a soft Dynamic-Island bubble (consistent,
        // generous bottom rounding instead of scaling huge on a tall panel).
        let topR = min(height * 0.5, 16)
        let baseBottomR = min(40, height * 0.5, width * 0.14)

        // The lag makes the bottom corners bulge outward and the bottom edge
        // sag downward — like the blob's mass hasn't finished settling.
        let bulge = bottomLag * min(28, width * 0.06)      // horizontal overshoot
        let sag = bottomLag * min(22, height * 0.18)        // vertical droop at center
        let bottomR = baseBottomR

        // --- Top-left corner (crisp, flush to screen) ---
        p.move(to: CGPoint(x: left, y: top + topR))
        p.addQuadCurve(
            to: CGPoint(x: left + topR, y: top),
            control: CGPoint(x: left, y: top)
        )

        // --- Top edge ---
        p.addLine(to: CGPoint(x: right - topR, y: top))

        // --- Top-right corner ---
        p.addQuadCurve(
            to: CGPoint(x: right, y: top + topR),
            control: CGPoint(x: right, y: top)
        )

        // --- Right edge down to the (bulging) bottom-right corner ---
        p.addLine(to: CGPoint(x: right + bulge, y: bottom - bottomR))
        p.addCurve(
            to: CGPoint(x: right - bottomR, y: bottom),
            control1: CGPoint(x: right + bulge, y: bottom),
            control2: CGPoint(x: right, y: bottom)
        )

        // --- Bottom edge: a liquid sag through the center ---
        p.addCurve(
            to: CGPoint(x: left + bottomR, y: bottom),
            control1: CGPoint(x: cx + width * 0.18, y: bottom + sag),
            control2: CGPoint(x: cx - width * 0.18, y: bottom + sag)
        )

        // --- Bottom-left (bulging) corner ---
        p.addCurve(
            to: CGPoint(x: left - bulge, y: bottom - bottomR),
            control1: CGPoint(x: left, y: bottom),
            control2: CGPoint(x: left - bulge, y: bottom)
        )

        // --- Left edge back up to where we started ---
        p.addLine(to: CGPoint(x: left, y: top + topR))

        p.closeSubpath()
        return p
    }
}

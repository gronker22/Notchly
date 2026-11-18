//
//  NotchShape.swift
//  Notchly
//
//  The bubble shape: a continuous-curvature ("squircle") rounded rectangle,
//  anchored to the TOP edge and growing DOWNWARD. No inward curves, no liquid
//  sag. `width`/`height` are animatable so the open/close morph interpolates
//  the path itself — including the corner radius, which scales with the
//  surface the way Apple's own containers do.
//
//  (`bottomLag` is kept in the signature for source compatibility with existing
//  call sites but no longer affects the geometry.)
//

import SwiftUI

struct NotchShape: Shape {
    var width: CGFloat
    var height: CGFloat
    var bottomLag: CGFloat = 0

    /// Corner radius that grows with the surface, instead of one fixed value
    /// serving both a 32pt pill and a 480x520 panel.
    ///
    /// A flat radius has to compromise: 22 is nearly half the height of the
    /// collapsed pill (so the pill can't read as a true capsule) yet only ~4%
    /// of the open panel (so the panel reads square). Apple's containers scale
    /// the radius with the surface — bigger surfaces get a bigger radius, but
    /// sub-linearly, so it never turns into a stadium.
    ///
    /// `sqrt` gives exactly that curve, and the `minDim / 2` clamp means the
    /// collapsed pill lands on a perfect capsule on its own:
    ///
    ///   minDim  32 -> 16.0 (capsule — half the height, can't exceed it)
    ///   minDim  74 -> 22.0 (unchanged from the old fixed value)
    ///   minDim 480 -> 36.0 (open panel, properly rounded)
    ///
    /// Because it's derived from the animating width/height, the radius
    /// interpolates through the open/close morph for free.
    private func cornerRadius(width w: CGFloat, height h: CGFloat) -> CGFloat {
        let minDim = min(w, h)
        guard minDim > 0 else { return 0 }
        return min(minDim / 2, 13 + 1.05 * sqrt(minDim))
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(width, height) }
        set {
            width = newValue.first
            height = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let cx = rect.midX
        let top = rect.minY
        let w = max(0, width)
        let h = max(0, height)

        let r = cornerRadius(width: w, height: h)

        let bubble = CGRect(x: cx - w / 2, y: top, width: w, height: h)
        return Path(roundedRect: bubble, cornerRadius: r, style: .continuous)
    }
}

//
//  NotchShape.swift
//  Notchly
//
//  The bubble shape: a clean rounded rectangle, anchored to the TOP edge and
//  growing DOWNWARD. All four corners use one consistent radius (no inward
//  curves, no liquid sag). `width`/`height` are animatable so the open/close
//  morph still interpolates the path itself.
//
//  (`bottomLag` is kept in the signature for source compatibility with existing
//  call sites but no longer affects the geometry.)
//

import SwiftUI

struct NotchShape: Shape {
    var width: CGFloat
    var height: CGFloat
    var bottomLag: CGFloat = 0

    /// Consistent corner radius for all four corners.
    private let cornerRadius: CGFloat = 22

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

        // Clamp the radius so it never exceeds half of the smaller dimension.
        let r = min(cornerRadius, w / 2, h / 2)

        let bubble = CGRect(x: cx - w / 2, y: top, width: w, height: h)
        return Path(roundedRect: bubble, cornerRadius: r, style: .continuous)
    }
}

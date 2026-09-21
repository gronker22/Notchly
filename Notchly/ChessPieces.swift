//
//  ChessPieces.swift
//  Notchly — vector chess pieces (Staunton style)
//
//  Real vector silhouettes instead of Unicode glyphs. Two wins:
//   * Looks like a proper chess set (shaded body + outline + carved detail).
//   * MUCH cheaper to draw — 2–3 path fills per piece instead of ~11 stacked
//     Text rasterizations, which is what made the board lag while animating.
//
//  All geometry is authored in a 100×100 box (baseline ≈ y 90) and scaled to fit.
//

import SwiftUI

// MARK: - Geometry (100×100 design space)

func chessPieceBodyPath(_ kind: PieceKind) -> Path {
    var p = Path()
    func base(_ x: CGFloat, _ w: CGFloat) {
        p.addRoundedRect(in: CGRect(x: x, y: 76, width: w, height: 14),
                         cornerSize: CGSize(width: 5, height: 5))
    }

    switch kind {
    case .pawn:
        p.addEllipse(in: CGRect(x: 36, y: 10, width: 28, height: 28))
        p.move(to: CGPoint(x: 36, y: 37))
        p.addQuadCurve(to: CGPoint(x: 64, y: 37), control: CGPoint(x: 50, y: 48))
        p.addCurve(to: CGPoint(x: 73, y: 76),
                   control1: CGPoint(x: 67, y: 52), control2: CGPoint(x: 71, y: 66))
        p.addLine(to: CGPoint(x: 27, y: 76))
        p.addCurve(to: CGPoint(x: 36, y: 37),
                   control1: CGPoint(x: 29, y: 66), control2: CGPoint(x: 33, y: 52))
        p.closeSubpath()
        base(22, 56)

    case .rook:
        p.move(to: CGPoint(x: 26, y: 16))
        p.addLine(to: CGPoint(x: 38, y: 16))
        p.addLine(to: CGPoint(x: 38, y: 25))
        p.addLine(to: CGPoint(x: 44, y: 25))
        p.addLine(to: CGPoint(x: 44, y: 16))
        p.addLine(to: CGPoint(x: 56, y: 16))
        p.addLine(to: CGPoint(x: 56, y: 25))
        p.addLine(to: CGPoint(x: 62, y: 25))
        p.addLine(to: CGPoint(x: 62, y: 16))
        p.addLine(to: CGPoint(x: 74, y: 16))
        p.addLine(to: CGPoint(x: 74, y: 34))
        p.addLine(to: CGPoint(x: 67, y: 41))
        p.addLine(to: CGPoint(x: 67, y: 66))
        p.addLine(to: CGPoint(x: 75, y: 76))
        p.addLine(to: CGPoint(x: 25, y: 76))
        p.addLine(to: CGPoint(x: 33, y: 66))
        p.addLine(to: CGPoint(x: 33, y: 41))
        p.addLine(to: CGPoint(x: 26, y: 34))
        p.closeSubpath()
        base(22, 56)

    case .bishop:
        p.addEllipse(in: CGRect(x: 45, y: 5, width: 10, height: 10))
        p.move(to: CGPoint(x: 50, y: 13))
        p.addCurve(to: CGPoint(x: 65, y: 44),
                   control1: CGPoint(x: 62, y: 17), control2: CGPoint(x: 66, y: 32))
        p.addCurve(to: CGPoint(x: 35, y: 44),
                   control1: CGPoint(x: 58, y: 53), control2: CGPoint(x: 42, y: 53))
        p.addCurve(to: CGPoint(x: 50, y: 13),
                   control1: CGPoint(x: 34, y: 32), control2: CGPoint(x: 38, y: 17))
        p.closeSubpath()
        p.addRoundedRect(in: CGRect(x: 33, y: 46, width: 34, height: 8),
                         cornerSize: CGSize(width: 3, height: 3))
        p.move(to: CGPoint(x: 38, y: 54))
        p.addLine(to: CGPoint(x: 62, y: 54))
        p.addCurve(to: CGPoint(x: 73, y: 76),
                   control1: CGPoint(x: 66, y: 62), control2: CGPoint(x: 70, y: 70))
        p.addLine(to: CGPoint(x: 27, y: 76))
        p.addCurve(to: CGPoint(x: 38, y: 54),
                   control1: CGPoint(x: 30, y: 70), control2: CGPoint(x: 34, y: 62))
        p.closeSubpath()
        base(21, 58)

    case .knight:
        p.move(to: CGPoint(x: 30, y: 76))
        p.addCurve(to: CGPoint(x: 31, y: 50),
                   control1: CGPoint(x: 27, y: 68), control2: CGPoint(x: 27, y: 56))
        p.addCurve(to: CGPoint(x: 20, y: 38),
                   control1: CGPoint(x: 33, y: 45), control2: CGPoint(x: 24, y: 42))
        p.addCurve(to: CGPoint(x: 27, y: 27),
                   control1: CGPoint(x: 16, y: 33), control2: CGPoint(x: 22, y: 28))
        p.addCurve(to: CGPoint(x: 40, y: 19),
                   control1: CGPoint(x: 31, y: 25), control2: CGPoint(x: 36, y: 21))
        p.addLine(to: CGPoint(x: 41, y: 8))
        p.addLine(to: CGPoint(x: 51, y: 19))
        p.addLine(to: CGPoint(x: 56, y: 9))
        p.addCurve(to: CGPoint(x: 70, y: 44),
                   control1: CGPoint(x: 67, y: 17), control2: CGPoint(x: 71, y: 30))
        p.addCurve(to: CGPoint(x: 70, y: 76),
                   control1: CGPoint(x: 69, y: 56), control2: CGPoint(x: 72, y: 68))
        p.closeSubpath()
        base(22, 56)

    case .queen:
        for (cx, r) in [(22.0, 5.0), (36.0, 5.0), (50.0, 5.5), (64.0, 5.0), (78.0, 5.0)] {
            let top: CGFloat = cx == 50 ? 7 : (cx == 36 || cx == 64 ? 10 : 15)
            p.addEllipse(in: CGRect(x: cx - r, y: top, width: r * 2, height: r * 2))
        }
        p.move(to: CGPoint(x: 22, y: 20))
        p.addLine(to: CGPoint(x: 31, y: 47))
        p.addLine(to: CGPoint(x: 36, y: 15))
        p.addLine(to: CGPoint(x: 43, y: 47))
        p.addLine(to: CGPoint(x: 50, y: 12))
        p.addLine(to: CGPoint(x: 57, y: 47))
        p.addLine(to: CGPoint(x: 64, y: 15))
        p.addLine(to: CGPoint(x: 69, y: 47))
        p.addLine(to: CGPoint(x: 78, y: 20))
        p.addLine(to: CGPoint(x: 72, y: 56))
        p.addLine(to: CGPoint(x: 28, y: 56))
        p.closeSubpath()
        p.addRoundedRect(in: CGRect(x: 26, y: 56, width: 48, height: 8),
                         cornerSize: CGSize(width: 3, height: 3))
        p.move(to: CGPoint(x: 31, y: 64))
        p.addLine(to: CGPoint(x: 69, y: 64))
        p.addCurve(to: CGPoint(x: 79, y: 76),
                   control1: CGPoint(x: 73, y: 68), control2: CGPoint(x: 77, y: 72))
        p.addLine(to: CGPoint(x: 21, y: 76))
        p.addCurve(to: CGPoint(x: 31, y: 64),
                   control1: CGPoint(x: 23, y: 72), control2: CGPoint(x: 27, y: 68))
        p.closeSubpath()
        base(19, 62)

    case .king:
        p.addRoundedRect(in: CGRect(x: 46.5, y: 3, width: 7, height: 23),
                         cornerSize: CGSize(width: 2.5, height: 2.5))
        p.addRoundedRect(in: CGRect(x: 39, y: 9.5, width: 22, height: 7),
                         cornerSize: CGSize(width: 2.5, height: 2.5))
        p.move(to: CGPoint(x: 28, y: 45))
        p.addCurve(to: CGPoint(x: 50, y: 29),
                   control1: CGPoint(x: 29, y: 36), control2: CGPoint(x: 39, y: 29))
        p.addCurve(to: CGPoint(x: 72, y: 45),
                   control1: CGPoint(x: 61, y: 29), control2: CGPoint(x: 71, y: 36))
        p.addLine(to: CGPoint(x: 74, y: 56))
        p.addLine(to: CGPoint(x: 26, y: 56))
        p.closeSubpath()
        p.addRoundedRect(in: CGRect(x: 26, y: 56, width: 48, height: 8),
                         cornerSize: CGSize(width: 3, height: 3))
        p.move(to: CGPoint(x: 31, y: 64))
        p.addLine(to: CGPoint(x: 69, y: 64))
        p.addCurve(to: CGPoint(x: 79, y: 76),
                   control1: CGPoint(x: 73, y: 68), control2: CGPoint(x: 77, y: 72))
        p.addLine(to: CGPoint(x: 21, y: 76))
        p.addCurve(to: CGPoint(x: 31, y: 64),
                   control1: CGPoint(x: 23, y: 72), control2: CGPoint(x: 27, y: 68))
        p.closeSubpath()
        base(19, 62)
    }
    return p
}

/// Carved detail lines, stroked on top of the body.
func chessPieceDetailPath(_ kind: PieceKind) -> Path {
    var p = Path()
    switch kind {
    case .pawn:
        p.move(to: CGPoint(x: 34, y: 74)); p.addLine(to: CGPoint(x: 66, y: 74))
    case .rook:
        p.move(to: CGPoint(x: 33, y: 46)); p.addLine(to: CGPoint(x: 67, y: 46))
        p.move(to: CGPoint(x: 33, y: 62)); p.addLine(to: CGPoint(x: 67, y: 62))
    case .bishop:
        // The signature mitre slit.
        p.move(to: CGPoint(x: 44, y: 34))
        p.addLine(to: CGPoint(x: 55, y: 23))
    case .knight:
        p.addEllipse(in: CGRect(x: 31.5, y: 31, width: 3.6, height: 3.6))   // eye
        p.move(to: CGPoint(x: 52, y: 22))                                    // mane
        p.addCurve(to: CGPoint(x: 62, y: 56),
                   control1: CGPoint(x: 60, y: 31), control2: CGPoint(x: 63, y: 45))
    case .queen:
        p.move(to: CGPoint(x: 29, y: 52)); p.addLine(to: CGPoint(x: 71, y: 52))
    case .king:
        p.move(to: CGPoint(x: 29, y: 52)); p.addLine(to: CGPoint(x: 71, y: 52))
    }
    return p
}

// MARK: - Shapes

struct ChessPieceBody: Shape {
    let kind: PieceKind
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 100
        return chessPieceBodyPath(kind).applying(
            CGAffineTransform(scaleX: s, y: s).concatenating(
                CGAffineTransform(translationX: rect.minX + (rect.width - 100 * s) / 2,
                                  y: rect.minY + (rect.height - 100 * s) / 2)))
    }
}

struct ChessPieceDetail: Shape {
    let kind: PieceKind
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 100
        return chessPieceDetailPath(kind).applying(
            CGAffineTransform(scaleX: s, y: s).concatenating(
                CGAffineTransform(translationX: rect.minX + (rect.width - 100 * s) / 2,
                                  y: rect.minY + (rect.height - 100 * s) / 2)))
    }
}

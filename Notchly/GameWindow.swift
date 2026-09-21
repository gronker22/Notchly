//
//  GameWindow.swift
//  Notchly — shared game-window plumbing
//
//  Lets the fixed-design casino views resize / go full screen by scaling the
//  table to fit the window, on a felt backdrop that fills the whole frame.
//

import SwiftUI
import AppKit

/// Scales `content` (authored at `designSize`) to fit the current window,
/// centered on a full-window felt backdrop.
struct ScalingGameContainer<Content: View>: View {
    let designSize: CGSize
    let content: Content

    init(designSize: CGSize, @ViewBuilder content: () -> Content) {
        self.designSize = designSize
        self.content = content()
    }

    var body: some View {
        GeometryReader { geo in
            let fit = min(geo.size.width / designSize.width,
                          geo.size.height / designSize.height)
            let scale = max(0.6, fit)
            ZStack {
                LinearGradient(colors: [Color(red: 0.04, green: 0.20, blue: 0.11),
                                        Color(red: 0.01, green: 0.09, blue: 0.05)],
                               startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [Color.white.opacity(0.04), .clear],
                               center: .center, startRadius: 40, endRadius: 700)
                content
                    .frame(width: designSize.width, height: designSize.height)
                    .scaleEffect(scale)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
    }
}

@MainActor
enum GameWindow {
    /// Creates a resizable, full-screen-capable window hosting a scaling table.
    static func make<V: View>(title: String, design: CGSize,
                              @ViewBuilder content: () -> V) -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: design),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        w.collectionBehavior.insert(.fullScreenPrimary)
        w.contentMinSize = CGSize(width: design.width * 0.7, height: design.height * 0.7)
        w.contentView = NSHostingView(
            rootView: ScalingGameContainer(design: design, content: content))
        w.center()
        return w
    }
}

private extension ScalingGameContainer {
    init(design: CGSize, @ViewBuilder content: () -> Content) {
        self.init(designSize: design, content: content)
    }
}

// MARK: - Casino felt + chip visuals (shared)

/// Rich green-felt table background with a centre spotlight, vignette and rail.
struct FeltBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.06, green: 0.34, blue: 0.18),
                                    Color(red: 0.02, green: 0.16, blue: 0.09)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color.white.opacity(0.08), .clear],
                           center: .center, startRadius: 20, endRadius: 320)
            RadialGradient(colors: [.clear, Color.black.opacity(0.4)],
                           center: .center, startRadius: 200, endRadius: 520)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(
                    LinearGradient(colors: [Color(white: 0.28), Color(white: 0.10)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 6)
                .padding(4)
                .opacity(0.5)
        )
    }
}

/// A stacked poker chip with a denomination colour and dashed edge.
struct PokerChip: View {
    let amount: Int
    var size: CGFloat = 26

    private var color: Color {
        switch amount {
        case ..<25:   return Color(red: 0.85, green: 0.2, blue: 0.2)   // red
        case ..<100:  return Color(red: 0.15, green: 0.45, blue: 0.9)  // blue
        case ..<500:  return Color(red: 0.15, green: 0.6, blue: 0.3)   // green
        default:      return Color(white: 0.12)                        // black
        }
    }

    var body: some View {
        ZStack {
            Circle().fill(color)
            Circle().strokeBorder(.white.opacity(0.9),
                                  style: StrokeStyle(lineWidth: max(2, size * 0.09), dash: [size * 0.16, size * 0.13]))
                .padding(size * 0.1)
            Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1).padding(size * 0.24)
            Text(shortAmount)
                .font(.system(size: size * 0.34, weight: .black, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
    }

    private var shortAmount: String {
        amount >= 1000 ? "\(amount / 1000)k" : "\(amount)"
    }
}

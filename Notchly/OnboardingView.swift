//
//  OnboardingView.swift
//  Notchly — first-run onboarding
//
//  A short, animated welcome shown once on first launch. Explains the core
//  interaction (hover the notch), where the off switch lives, and the optional
//  permissions. Motion is built natively in SwiftUI (spring page transitions +
//  a gently animated notch illustration) so it stays smooth.
//

import SwiftUI
import AppKit

struct OnboardingView: View {
    var onFinish: () -> Void

    @State private var page = 0
    @State private var appear = false
    private let pageCount = 4

    var body: some View {
        ZStack {
            // Animated backdrop.
            LinearGradient(colors: [Color(red: 0.10, green: 0.09, blue: 0.20),
                                    Color(red: 0.03, green: 0.03, blue: 0.06)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                ZStack {
                    switch page {
                    case 0: welcomePage
                    case 1: hoverPage
                    case 2: offSwitchPage
                    default: permissionsPage
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)))
                .id(page)

                Spacer(minLength: 0)

                footer
            }
            .padding(36)
        }
        .frame(width: 620, height: 520)
        .onAppear { withAnimation(.easeOut(duration: 0.5)) { appear = true } }
    }

    // MARK: Pages

    private var welcomePage: some View {
        VStack(spacing: 20) {
            AnimatedNotch()
                .frame(width: 220, height: 74)
            Text("Meet Notchly")
                .font(.system(size: 34, design: .rounded).weight(.black))
                .foregroundStyle(.white)
            Text("Your Mac's notch, turned into a Dynamic-Island-style hub for music, timers, calendar, system stats, and a few games.")
                .multilineTextAlignment(.center)
                .font(.system(.title3, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
                .frame(maxWidth: 460)
        }
    }

    private var hoverPage: some View {
        pageScaffold(
            icon: "cursorarrow.rays",
            title: "Hover to open",
            body: "Move your pointer over the top-center notch and Notchly expands into the full island. Move away and it tucks back to a slim pill. It never steals your clicks.")
    }

    private var offSwitchPage: some View {
        pageScaffold(
            icon: "menubar.arrow.up.rectangle",
            title: "Turn it off anytime",
            body: "Notchly lives in your menu bar too. Click its icon (top-right) → Quit Notchly, or open Settings from the notch's gear and hit Quit. You can also enable ‘Launch at login’ in Settings.")
    }

    private var permissionsPage: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 40)).foregroundStyle(.white)
            Text("Optional permissions")
                .font(.system(.title, design: .rounded).weight(.bold))
                .foregroundStyle(.white)
            Text("Grant only what you want — each unlocks one module. You can do this later in System Settings.")
                .multilineTextAlignment(.center)
                .font(.system(.callout, design: .rounded))
                .foregroundStyle(.white.opacity(0.65))
                .frame(maxWidth: 480)

            VStack(spacing: 8) {
                permissionRow("calendar", "Calendar", "Show your next event", Self.calendarURL)
                permissionRow("bell.badge", "Notifications peek", "Needs Full Disk Access", Self.fullDiskURL)
                permissionRow("music.note", "Now Playing", "Control Spotify / Music", Self.automationURL)
                permissionRow("macwindow.on.rectangle", "Window docking", "Needs Accessibility", Self.accessibilityURL)
            }
            .frame(maxWidth: 480)
        }
    }

    private func permissionRow(_ icon: String, _ title: String, _ subtitle: String, _ url: URL) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(.white).frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(.callout, design: .rounded).weight(.semibold)).foregroundStyle(.white)
                Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            Button("Open") { NSWorkspace.shared.open(url) }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.06)))
    }

    private func pageScaffold(icon: String, title: String, body: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: icon)
                .font(.system(size: 46)).foregroundStyle(.white)
                .symbolEffect(.pulse, options: .repeating)
            Text(title)
                .font(.system(size: 30, design: .rounded).weight(.bold))
                .foregroundStyle(.white)
            Text(body)
                .multilineTextAlignment(.center)
                .font(.system(.title3, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
                .frame(maxWidth: 460)
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 18) {
            HStack(spacing: 8) {
                ForEach(0..<pageCount, id: \.self) { i in
                    Capsule()
                        .fill(i == page ? Color.white : Color.white.opacity(0.25))
                        .frame(width: i == page ? 22 : 7, height: 7)
                        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: page)
                }
            }

            HStack {
                Button("Skip") { onFinish() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                Button {
                    if page < pageCount - 1 {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { page += 1 }
                    } else {
                        onFinish()
                    }
                } label: {
                    Text(page < pageCount - 1 ? "Next" : "Get started")
                        .font(.system(.headline, design: .rounded).weight(.bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 22).padding(.vertical, 11)
                        .background(Capsule().fill(.white))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // System Settings privacy deep-links.
    static let calendarURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!
    static let fullDiskURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    static let automationURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
    static let accessibilityURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
}

// MARK: - Animated notch illustration

private struct AnimatedNotch: View {
    @State private var wide = false
    var body: some View {
        NotchShape(width: wide ? 220 : 150, height: 74, bottomLag: 0)
            .fill(.black)
            .overlay(
                NotchShape(width: wide ? 220 : 150, height: 74, bottomLag: 0)
                    .stroke(.white.opacity(0.15), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
            .frame(width: 220, height: 74)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { wide = true }
            }
    }
}

// MARK: - Window presenter

@MainActor
enum OnboardingWindowPresenter {
    private static var window: NSWindow?

    static func show(onFinish: @escaping () -> Void) {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }

        let finish: () -> Void = {
            window?.close()
            window = nil
            onFinish()
        }
        let hosting = NSHostingController(rootView: OnboardingView(onFinish: finish))
        let w = NSWindow(contentViewController: hosting)
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.title = "Welcome to Notchly"
        w.setContentSize(NSSize(width: 620, height: 520))
        w.center()
        w.isReleasedWhenClosed = false
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

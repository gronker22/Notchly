//
//  NotchView.swift
//  Notchly — Phase 1
//
//  The SwiftUI surface drawn inside the panel. It renders the NotchShape blob
//  in pure black and morphs between the collapsed pill and the expanded island
//  using two springs: a primary one for size (the Phase 1 spec: stiffness 180,
//  damping 16) and a slightly softer one for `bottomLag`, so the bottom edge
//  trails the rest of the blob and feels like settling liquid.
//

import SwiftUI
import Combine

/// Shared, observable hover/expansion state. The AppKit tracking area (see
/// NotchWindowController) flips `isExpanded`; SwiftUI animates off it.
final class NotchState: ObservableObject {
    @Published var isExpanded: Bool = false

    /// Current visible height of the expanded bubble, so the controller's hover
    /// logic only keeps it open while the cursor is over the actual bubble (not
    /// the empty area below it inside the fixed panel frame).
    @Published var bubbleHeight: CGFloat = 0

    // Drag-to-dock state.
    enum DropHalf { case left, right }
    @Published var isDragTargeting: Bool = false   // a drag is hovering the island
    @Published var dragHalf: DropHalf? = nil        // which zone is highlighted
}

/// Reports the expanded content's natural height up to the bubble.
private struct ExpandedHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct NotchView: View {
    @ObservedObject var state: NotchState
    let geometry: NotchGeometry

    // Now Playing
    @StateObject private var nowPlaying = NowPlayingManager()

    // PHASE 3: productivity modules
    @StateObject private var pomodoro = PomodoroManager()
    @StateObject private var calendar = CalendarManager()

    // PHASE 4: system awareness + clipboard
    @StateObject private var media = MediaAccessMonitor()
    @StateObject private var network = NetworkMonitor()
    @StateObject private var clipboard = ClipboardManager()

    // Live sports
    @StateObject private var sports = SportsManager()

    // Incoming-notification peek
    @StateObject private var notifications = NotificationInterceptor()
    @State private var bannerItem: NotificationItem?
    @State private var bannerDismiss: DispatchWorkItem?

    // Spring-driven, path-level animation parameters.
    @State private var width: CGFloat
    @State private var height: CGFloat

    // PHASE 3: drives the imminent-event glow pulse.
    @State private var pulse = false

    // PHASE 5: 0 = single pill, 1 = fully split into two pills.
    @State private var splitProgress: CGFloat = 0

    // Measured natural height of the expanded content, so the bubble sizes to
    // its content instead of leaving a fixed black void below.
    @State private var measuredContentHeight: CGFloat = 0

    init(state: NotchState, geometry: NotchGeometry) {
        self.state = state
        self.geometry = geometry
        _width = State(initialValue: geometry.collapsedWidth)
        _height = State(initialValue: geometry.collapsedIdleHeight)
    }

    /// Is there any collapsed content worth dropping the pill down for?
    private var collapsedHasInfo: Bool {
        pomodoro.isRunning
            || network.showsTicker
            || media.micActive
            || media.cameraActive
            || (sports.isSportsEnabled && sports.liveGames.contains { $0.state == .live })
    }

    /// Collapsed pill height: flush when idle, dropped a little when showing info.
    private var collapsedTargetHeight: CGFloat {
        collapsedHasInfo ? geometry.collapsedHeight : geometry.collapsedIdleHeight
    }

    // Spring for the open/close size morph.
    private var sizeSpring: Animation {
        .spring(response: 0.4, dampingFraction: 0.7)
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Single blob, or two split pills.
            bubbleBackground

            // Collapsed presentation (hidden while a notification banner shows).
            if bannerItem == nil {
                if showSplit {
                    splitContent
                } else {
                    collapsedContent
                }
            }

            // Expanded: full module stack.
            expandedContent

            // Incoming-notification peek (morphs the collapsed notch for 3s).
            bannerOverlay

            // PHASE 6: drag-to-dock zones, shown only while a drag is targeting.
            if state.isDragTargeting {
                dropZones
            }
        }
        // The view fills the whole (expanded-sized) panel; the shape draws
        // itself anchored to the top, so the panel never needs to resize.
        .frame(
            width: geometry.expandedWidth,
            height: geometry.expandedHeight,
            alignment: .top
        )
        .onChange(of: state.isExpanded) { _, expanded in
            animate(to: expanded)
        }
        .onPreferenceChange(ExpandedHeightKey.self) { h in
            measuredContentHeight = h
            // Publish the real bubble height so the controller's hover hit-test
            // matches the visible bubble.
            state.bubbleHeight = expandedTargetHeight
            // If already open, grow/shrink the bubble to match new content
            // (e.g. clipboard items added, track row appearing).
            if state.isExpanded {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                    height = expandedTargetHeight
                }
            }
        }
        .onAppear {
            nowPlaying.start()
            // PHASE 3: start calendar (Pomodoro starts on user action).
            calendar.start()
            // PHASE 4: start system-awareness + clipboard.
            media.start()
            network.start()
            clipboard.start()
            // Live sports polling.
            sports.start()
            // Incoming notification peek.
            notifications.start()
        }
        .onChange(of: notifications.latest) { _, item in
            if let item { showBanner(item) }
        }
        // Drop the collapsed pill down only while there's info to show.
        .onChange(of: collapsedHasInfo) { _, _ in
            if !state.isExpanded && bannerItem == nil {
                withAnimation(sizeSpring) { height = collapsedTargetHeight }
            }
        }
        // PHASE 3: drive the imminent-event pulse loop.
        .onChange(of: calendar.isImminent) { _, imminent in
            if imminent {
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            } else {
                withAnimation(.easeInOut(duration: 0.3)) { pulse = false }
            }
        }
        // PHASE 5: animate the split using the Phase 1 spring family.
        .onChange(of: isSplitCondition) { _, split in
            withAnimation(.interpolatingSpring(stiffness: 180, damping: 16)) {
                splitProgress = split ? 1 : 0
            }
        }
    }

    // MARK: - Bubble background (single / split)

    /// Split only happens while collapsed.
    private var isSplitCondition: Bool { pomodoro.isRunning && calendar.isImminent }
    private var showSplit: Bool { isSplitCondition && !state.isExpanded }

    private var splitPillWidth: CGFloat { geometry.collapsedWidth * 0.46 }
    private var splitDX: CGFloat { splitProgress * geometry.collapsedWidth * 0.30 }

    @ViewBuilder
    private var bubbleBackground: some View {
        Group {
            if showSplit {
                ZStack(alignment: .top) {
                    NotchShape(width: splitPillWidth, height: geometry.collapsedHeight, bottomLag: 0)
                        .fill(Color.black)
                        .offset(x: -splitDX)
                    NotchShape(width: splitPillWidth, height: geometry.collapsedHeight, bottomLag: 0)
                        .fill(Color.black)
                        .offset(x: splitDX)
                }
                .frame(width: geometry.expandedWidth, height: geometry.expandedHeight, alignment: .top)
            } else {
                NotchShape(width: width, height: height)
                    .fill(Color.black)               // pure #000000 to blend with the notch
            }
        }
    }

    // MARK: - PHASE 6: drag-to-dock zones

    @ViewBuilder
    private var dropZones: some View {
        HStack(spacing: 8) {
            dropZone(title: "Left half", system: "rectangle.lefthalf.inset.filled",
                     active: state.dragHalf == .left)
            dropZone(title: "Right half", system: "rectangle.righthalf.inset.filled",
                     active: state.dragHalf == .right)
        }
        .padding(12)
        .padding(.top, geometry.collapsedHeight)
        .frame(width: geometry.expandedWidth, height: geometry.expandedHeight)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.15), value: state.dragHalf)
    }

    private func dropZone(title: String, system: String, active: Bool) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.white.opacity(active ? 0.22 : 0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(active ? 0.8 : 0.25),
                                  style: StrokeStyle(lineWidth: active ? 2 : 1, dash: [6, 4]))
            )
            .overlay(
                VStack(spacing: 6) {
                    Image(systemName: system)
                        .font(.system(size: 22, weight: .semibold))
                    Text(title)
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                }
                .foregroundStyle(.white.opacity(active ? 1 : 0.6))
            )
            .scaleEffect(active ? 1.0 : 0.97)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - PHASE 5: split content (left = timer, right = event warning)

    @ViewBuilder
    private var splitContent: some View {
        ZStack(alignment: .top) {
            // Left pill: Pomodoro ring + remaining time.
            ZStack {
                Canvas { ctx, size in
                    let rect = CGRect(origin: .zero, size: size)
                    let pill = NotchShape(width: size.width, height: size.height, bottomLag: 0)
                        .path(in: rect)
                    let arc = pill.trimmedPath(from: 0, to: pomodoro.progress)
                    ctx.stroke(arc, with: .color(.white),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                Text(pomodoro.remainingString)
                    .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .id(pomodoro.tickToken)
            }
            .frame(width: splitPillWidth, height: geometry.collapsedHeight)
            .offset(x: -splitDX)

            // Right pill: pulsing event warning + countdown.
            ZStack {
                NotchShape(width: splitPillWidth, height: geometry.collapsedHeight, bottomLag: 0)
                    .fill(Color.white)
                    .blur(radius: 8)
                    .opacity(pulse ? 0.5 : 0.1)
                HStack(spacing: 3) {
                    Image(systemName: "calendar")
                        .font(.system(size: 8, weight: .bold))
                    Text(calendar.countdownString ?? "")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white)
            }
            .frame(width: splitPillWidth, height: geometry.collapsedHeight)
            .offset(x: splitDX)
        }
        .frame(width: geometry.expandedWidth, height: geometry.expandedHeight, alignment: .top)
        .opacity(splitProgress)
        .allowsHitTesting(false)
    }

    // MARK: - Collapsed pill content

    @ViewBuilder
    private var collapsedContent: some View {
        ZStack {
            // PHASE 3: soft white glow that pulses when an event is <5 min away.
            NotchShape(width: geometry.collapsedWidth, height: geometry.collapsedHeight, bottomLag: 0)
                .fill(Color.white)
                .blur(radius: 9)
                .opacity(calendar.isImminent ? (pulse ? 0.55 : 0.0) : 0)

            // PHASE 3: Pomodoro progress ring wrapping the pill's outer edge.
            // Drawn in a Canvas and re-rendered each frame by TimelineView so the
            // arc sweeps smoothly (continuous progress) rather than stepping once
            // per second.
            TimelineView(.animation) { _ in
                Canvas { ctx, size in
                    let rect = CGRect(origin: .zero, size: size)
                    let pill = NotchShape(width: size.width, height: size.height, bottomLag: 0)
                        .path(in: rect)
                    let arc = pill.trimmedPath(from: 0, to: pomodoro.progress)
                    ctx.stroke(
                        arc,
                        with: .color(.white),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                    )
                }
            }
            .opacity(pomodoro.isRunning ? 1 : 0)

            // Leading (Pomodoro time + network ticker) / trailing (media dots).
            HStack(spacing: 6) {
                // Remaining-time countdown, visible in the collapsed notch.
                if pomodoro.isRunning {
                    Text(pomodoro.remainingString)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .id(pomodoro.tickToken)   // refresh each second
                }

                // PHASE 4: network ticker, only above 500 KB/s, fades when idle.
                if network.showsTicker {
                    Text(network.tickerString)
                        .font(.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                        .transition(.opacity)
                }

                // Live sports score ticker (cycles when multiple games are live).
                if sports.isSportsEnabled {
                    SportsTicker(sports: sports)
                }

                Spacer(minLength: 0)

                // PHASE 4: mic/camera dots + the using app's icon (16x16).
                collapsedMediaIndicator
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 3)
            // Sit the info row in the strip BELOW the notch (live screen), so the
            // running countdown etc. is actually visible and not hidden in the notch.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .animation(.easeInOut(duration: 0.25), value: network.showsTicker)
            .animation(.easeInOut(duration: 0.25), value: media.micActive)
            .animation(.easeInOut(duration: 0.25), value: media.cameraActive)
        }
        .frame(width: geometry.collapsedWidth, height: geometry.collapsedHeight)
        .opacity(state.isExpanded ? 0 : 1)
        .animation(.easeInOut(duration: 0.15), value: state.isExpanded)
        .allowsHitTesting(false)
    }

    // MARK: - Expanded island content

    @ViewBuilder
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .top, spacing: 16) {
            // LEFT column: Pomodoro, Calendar, Network, Clipboard.
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 14) {
                    pomodoroControls
                    Rectangle()
                        .fill(.white.opacity(0.12))
                        .frame(width: 1, height: 30)
                    calendarRow
                    Spacer(minLength: 0)
                }

                HStack(alignment: .center, spacing: 12) {
                    Label(network.fullString, systemImage: "dot.radiowaves.up.forward")
                        .font(.system(.caption2, design: .rounded).weight(.medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.75))
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    mediaAccessRow
                }

                clipboardList
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // RIGHT column: Now Playing — album art on top, then title/artist
            // and the transport controls beneath it.
            VStack(alignment: .center, spacing: 8) {
                artworkView

                VStack(spacing: 2) {
                    Text(nowPlaying.title)
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    if !nowPlaying.artist.isEmpty {
                        Text(nowPlaying.artist)
                            .font(.system(.caption2, design: .rounded))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                            .multilineTextAlignment(.center)
                    }
                }

                transportControls
            }
            .frame(width: 150)
        }

            // Sports section (Live / Yesterday) — only when enabled.
            if sports.isSportsEnabled {
                Rectangle().fill(.white.opacity(0.10)).frame(height: 1)
                SportsView(sports: sports)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, geometry.collapsedHeight + 8)
        .padding(.bottom, 16)
        .frame(width: geometry.expandedWidth, alignment: .top)
        // Measure the content's natural height so the bubble fits it exactly.
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: ExpandedHeightKey.self, value: proxy.size.height)
            }
        )
        .frame(maxHeight: geometry.expandedHeight, alignment: .top)
        .opacity(state.isExpanded ? 1 : 0)
        .animation(.easeInOut(duration: 0.18), value: state.isExpanded)
        .allowsHitTesting(state.isExpanded)
    }

    @ViewBuilder
    private var artworkView: some View {
        Group {
            if let art = nowPlaying.artwork {
                Image(nsImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(0.12))
                    .overlay(
                        Image(systemName: "music.note")
                            .foregroundStyle(.white.opacity(0.5))
                    )
            }
        }
        .frame(width: 76, height: 76)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var transportControls: some View {
        HStack(spacing: 14) {
            controlButton("backward.fill") { nowPlaying.previousTrack() }
            controlButton(nowPlaying.isPlaying ? "pause.fill" : "play.fill") { nowPlaying.togglePlayPause() }
            controlButton("forward.fill") { nowPlaying.nextTrack() }
        }
    }

    private func controlButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - PHASE 3: Pomodoro controls (expanded)

    @ViewBuilder
    private var pomodoroControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: pomodoro.phase == .work ? "brain.head.profile" : "cup.and.saucer.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Text(pomodoro.phase == .work ? "Focus" : "Break")
                    .font(.system(.caption2, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .fixedSize()                // never wrap "Focus" → "Fo-cus"
                Text(pomodoro.remainingString)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
                    .id(pomodoro.tickToken)
            }
            .fixedSize(horizontal: true, vertical: false)
            HStack(spacing: 12) {
                controlButton(pomodoro.isRunning ? "pause.fill" : "play.fill") { pomodoro.startPause() }
                controlButton("arrow.counterclockwise") { pomodoro.reset() }

                // Adjust the current phase length (only while paused/idle).
                if !pomodoro.isRunning {
                    HStack(spacing: 6) {
                        controlButton("minus") { pomodoro.adjustMinutes(by: -5) }
                        controlButton("plus") { pomodoro.adjustMinutes(by: 5) }
                    }
                    .opacity(0.8)
                }
            }
        }
    }

    // MARK: - PHASE 3: Calendar event row (expanded)

    @ViewBuilder
    private var calendarRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Text("Next")
                    .font(.system(.caption2, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            if calendar.hasEvent, let title = calendar.nextEventTitle {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(.caption, design: .rounded).weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let countdown = calendar.countdownString {
                        Text(countdown)
                            .font(.system(.caption2, design: .rounded).weight(.semibold))
                            .foregroundStyle(calendar.isImminent ? .orange : .white.opacity(0.6))
                    }
                }
            } else {
                Text("No upcoming events")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }
        }
    }

    // MARK: - PHASE 4: Mic/camera (collapsed indicator)

    @ViewBuilder
    private var collapsedMediaIndicator: some View {
        if media.micActive || media.cameraActive {
            HStack(spacing: 4) {
                if media.micActive {
                    Circle().fill(.orange).frame(width: 6, height: 6)
                }
                if media.cameraActive {
                    Circle().fill(.green).frame(width: 6, height: 6)
                }
                if let icon = (media.cameraApp ?? media.micApp)?.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 16, height: 16)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }
            .transition(.opacity)
        }
    }

    // MARK: - PHASE 4: Mic/camera (expanded row)

    @ViewBuilder
    private var mediaAccessRow: some View {
        if let info = activeMediaInfo {
            HStack(spacing: 6) {
                if let icon = info.app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 16, height: 16)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(info.app.name)
                        .font(.system(.caption2, design: .rounded).weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("Using \(info.kind) since \(timeString(info.app.since))")
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
        }
    }

    /// Picks which capture session to describe in the expanded row.
    private var activeMediaInfo: (app: MediaAccessMonitor.AppInfo, kind: String)? {
        if media.micActive && media.cameraActive, let app = media.cameraApp {
            return (app, "microphone & camera")
        }
        if media.cameraActive, let app = media.cameraApp { return (app, "camera") }
        if media.micActive, let app = media.micApp { return (app, "microphone") }
        return nil
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm"
        return f.string(from: date)
    }

    // MARK: - PHASE 4: Clipboard history (expanded)

    @ViewBuilder
    private var clipboardList: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Text("Clipboard")
                    .font(.system(.caption2, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
            }

            if clipboard.items.isEmpty {
                Text("Nothing copied yet")
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
            } else {
                ForEach(Array(clipboard.items.enumerated()), id: \.offset) { index, item in
                    Button {
                        clipboard.copy(item, at: index)
                    } label: {
                        HStack {
                            Text(truncate(item, to: 40))
                                .font(.system(.caption2, design: .rounded))
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            if clipboard.flashIndex == index {
                                Text("Copied!")
                                    .font(.system(size: 9, weight: .bold, design: .rounded))
                                    .foregroundStyle(.green)
                                    .transition(.opacity)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.15), value: clipboard.flashIndex)
    }

    private func truncate(_ s: String, to n: Int) -> String {
        let collapsed = s.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return collapsed.count <= n ? collapsed : String(collapsed.prefix(n - 1)) + "…"
    }

    /// Expanded bubble height = measured content height, clamped to the panel.
    private var expandedTargetHeight: CGFloat {
        let h = measuredContentHeight > 0 ? measuredContentHeight : geometry.expandedHeight
        return min(geometry.expandedHeight, max(geometry.collapsedHeight, h))
    }

    // MARK: - Incoming notification banner

    private var bannerWidth: CGFloat { min(geometry.expandedWidth, 360) }
    private var bannerHeight: CGFloat { geometry.collapsedHeight + 26 }

    @ViewBuilder
    private var bannerOverlay: some View {
        if let item = bannerItem, !state.isExpanded {
            HStack(spacing: 10) {
                if let icon = appIcon(item.bundleID) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 26, height: 26)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title.isEmpty ? appName(item.bundleID) : item.title)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if !item.body.isEmpty {
                        Text(firstLine(item.body))
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
            .frame(width: bannerWidth, height: bannerHeight, alignment: .bottom)
            .transition(.opacity)
            .allowsHitTesting(false)
        }
    }

    private func showBanner(_ item: NotificationItem) {
        // Don't interrupt an open panel.
        guard !state.isExpanded else { return }

        bannerItem = item
        withAnimation(sizeSpring) {
            width = bannerWidth
            height = bannerHeight
        }

        bannerDismiss?.cancel()
        let work = DispatchWorkItem {
            bannerItem = nil
            if !state.isExpanded {
                withAnimation(sizeSpring) {
                    width = geometry.collapsedWidth
                    height = geometry.collapsedHeight
                }
            }
        }
        bannerDismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func appIcon(_ bundleID: String) -> NSImage? {
        guard !bundleID.isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return "Notification"
        }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }

    private func firstLine(_ s: String) -> String {
        s.components(separatedBy: .newlines).first ?? s
    }

    private func animate(to expanded: Bool) {
        let targetW = expanded ? geometry.expandedWidth : geometry.collapsedWidth
        let targetH = expanded ? expandedTargetHeight : collapsedTargetHeight

        withAnimation(sizeSpring) {
            width = targetW
            height = targetH
        }
    }
}

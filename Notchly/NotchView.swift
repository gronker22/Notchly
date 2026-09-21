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

    /// True while a file drag is hovering the island (drives the shelf highlight).
    @Published var isDragTargeting: Bool = false
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

    // Cross-cutting user prefs (per-module toggles, launch at login).
    @ObservedObject private var settings = NotchSettings.shared

    // Now Playing
    @StateObject private var nowPlaying = NowPlayingManager()

    // PHASE 3: productivity modules
    @StateObject private var pomodoro = PomodoroManager()
    @StateObject private var calendar = CalendarManager()

    // PHASE 4: system awareness + clipboard
    @StateObject private var media = MediaAccessMonitor()
    @StateObject private var clipboard = ClipboardManager()
    @StateObject private var wifi = WiFiMonitor()
    @StateObject private var systemStats = SystemStatsManager()
    @ObservedObject private var shelf = FileShelf.shared

    // Live sports
    @StateObject private var sports = SportsManager()

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
        (settings.showPomodoro && pomodoro.isRunning)
            || (settings.showMediaAccess && (media.micActive || media.cameraActive))
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

            // Collapsed presentation.
            if showSplit {
                splitContent
            } else {
                collapsedContent
            }

            // Expanded: full module stack.
            expandedContent

            if state.isDragTargeting { dropHighlight }
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
            // Battery: modules that only appear in the expanded panel poll only
            // while it's open. Collapsed, they go quiet (no AppleScript / CoreWLAN
            // wakeups), which lets the CPU idle instead of running ~15% forever.
            nowPlaying.setActive(expanded && settings.showNowPlaying)
            wifi.setActive(expanded && settings.showSystemStats)
            systemStats.setActive(expanded && settings.showSystemStats)
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
            // Only start the managers for modules the user has enabled — a
            // disabled module then does zero polling (battery + declutter).
            if settings.showNowPlaying { nowPlaying.start() }
            if settings.showCalendar { calendar.start() }   // Pomodoro starts on user action.
            if settings.showMediaAccess { media.start() }
            if settings.showClipboard { clipboard.start() }
            if settings.showSystemStats { systemStats.start(); wifi.start() }
            sports.start()                                   // has its own in-panel toggle
        }
        // Drop the collapsed pill down only while there's info to show.
        .onChange(of: collapsedHasInfo) { _, _ in
            if !state.isExpanded {
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

            // Content sits BESIDE the physical notch: timer on the left flank,
            // mic/camera + sports on the right flank, notch gap in the middle.
            HStack(spacing: 0) {
                // LEFT flank
                HStack(spacing: 5) {
                    Spacer(minLength: 0)
                    if settings.showPomodoro && pomodoro.isRunning {
                        Text(pomodoro.remainingString)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                            .id(pomodoro.tickToken)
                    }
                }
                .frame(width: geometry.flankWidth)
                .padding(.trailing, 4)

                // Notch gap (empty — the physical camera housing).
                Color.clear.frame(width: geometry.notchGap)

                // RIGHT flank
                HStack(spacing: 5) {
                    if settings.showMediaAccess { collapsedMediaIndicator }
                    if sports.isSportsEnabled {
                        SportsTicker(sports: sports)
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: geometry.flankWidth)
                .padding(.leading, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.25), value: media.micActive)
            .animation(.easeInOut(duration: 0.25), value: media.cameraActive)
        }
        .frame(width: geometry.collapsedWidth, height: geometry.collapsedHeight)
        .opacity(state.isExpanded ? 0 : 1)
        .animation(.easeInOut(duration: 0.15), value: state.isExpanded)
        .allowsHitTesting(false)
    }

    // MARK: - File shelf

    /// Shown over the whole island while files are dragged onto it.
    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(.white.opacity(0.10))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.75),
                                  style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
            )
            .overlay(
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 26, weight: .semibold))
                    Text("Drop to add to the shelf")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                }
                .foregroundStyle(.white)
            )
            .padding(10)
            .padding(.top, geometry.collapsedHeight)
            .frame(width: geometry.expandedWidth, height: geometry.expandedHeight)
            .transition(.opacity)
    }

    @ViewBuilder
    private var shelfRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "tray.full.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Text("Shelf")
                    .font(.system(.caption2, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer(minLength: 0)
                if !shelf.isEmpty {
                    Button { shelf.clear() } label: {
                        Text("Clear")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
            }

            if shelf.isEmpty {
                Text("Drag files onto the notch to park them here")
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(shelf.items) { shelfChip($0) }
                    }
                    .padding(.top, 3)       // room for the remove badge
                    .padding(.trailing, 4)
                }
                .frame(height: 58)
            }
        }
    }

    private func shelfChip(_ item: FileShelf.Item) -> some View {
        VStack(spacing: 3) {
            Image(nsImage: shelf.icon(for: item))
                .resizable()
                .frame(width: 26, height: 26)
            Text(item.name)
                .font(.system(size: 8, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 54)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.09)))
        .overlay(alignment: .topTrailing) {
            Button { shelf.remove(item) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.65))
                    .background(Circle().fill(.black.opacity(0.45)))
            }
            .buttonStyle(.plain)
            .offset(x: 4, y: -4)
        }
        // Drag straight back out into Finder or any app.
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .onTapGesture(count: 2) { shelf.reveal(item) }
        .help(item.url.path)
    }

    // MARK: - Expanded island content

    @ViewBuilder
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Sports leads the panel — it's the thing Notchly does that nothing
            // else does.
            if sports.isSportsEnabled {
                SportsView(sports: sports)
                Rectangle().fill(.white.opacity(0.10)).frame(height: 1)
            }

        HStack(alignment: .top, spacing: 16) {
            // LEFT column: Pomodoro, Calendar, Network, Clipboard, System stats.
            VStack(alignment: .leading, spacing: 12) {
                if settings.showPomodoro || settings.showCalendar {
                    HStack(alignment: .center, spacing: 14) {
                        if settings.showPomodoro { pomodoroControls }
                        if settings.showPomodoro && settings.showCalendar {
                            Rectangle()
                                .fill(.white.opacity(0.12))
                                .frame(width: 1, height: 30)
                        }
                        if settings.showCalendar { calendarRow }
                        Spacer(minLength: 0)
                    }
                }

                if settings.showMediaAccess {
                    HStack(alignment: .center, spacing: 10) {
                        cameraMirrorButton
                        Spacer(minLength: 0)
                        mediaAccessRow
                    }
                }

                if settings.showSystemStats { systemStatsRow }

                if settings.showClipboard { clipboardList }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // RIGHT column: Now Playing — album art on top, then title/artist
            // and the transport controls beneath it.
            if settings.showNowPlaying {
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

                    nowPlayingScrubber

                    transportControls
                }
                .frame(width: 150)
            }
        }

            // File shelf — drag files onto the notch to park them.
            shelfRow

            // Always-visible footer: settings + the sports on/off switch, so
            // sports can be re-enabled even when its section is hidden.
            Rectangle().fill(.white.opacity(0.10)).frame(height: 1)
            panelFooter
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

    // MARK: - Now Playing scrubber + volume (polish)

    @ViewBuilder
    private var nowPlayingScrubber: some View {
        if nowPlaying.hasTrack && nowPlaying.duration > 0 {
            VStack(spacing: 7) {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let pos = nowPlaying.interpolatedPosition(at: context.date)
                    let frac = min(1, max(0, pos / nowPlaying.duration))
                    VStack(spacing: 3) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.18))
                                Capsule().fill(.white.opacity(0.9))
                                    .frame(width: geo.size.width * frac)
                            }
                            .frame(height: 4)
                            .frame(maxHeight: .infinity, alignment: .center)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0).onEnded { v in
                                    nowPlaying.seek(toFraction: v.location.x / geo.size.width)
                                }
                            )
                        }
                        .frame(height: 10)
                        // Timestamps on their own row, cleanly below the bar.
                        HStack {
                            Text(NowPlayingManager.timeString(pos))
                            Spacer()
                            Text(NowPlayingManager.timeString(nowPlaying.duration))
                        }
                        .font(.system(size: 8, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.5))
                    }
                }

                // Volume
                HStack(spacing: 6) {
                    Image(systemName: "speaker.fill")
                        .font(.system(size: 8)).foregroundStyle(.white.opacity(0.5))
                    Slider(value: Binding(
                        get: { nowPlaying.volume },
                        set: { nowPlaying.setVolume($0) }
                    ), in: 0...1)
                    .controlSize(.mini)
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 8)).foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(width: 140)
            .padding(.top, 2)
        }
    }

    // MARK: - System stats peek (CPU / memory / network)

    private var systemStatsRow: some View {
        HStack(spacing: 16) {
            statGauge(icon: "cpu", value: systemStats.cpuUsage,
                      text: systemStats.cpuPercentString, tint: cpuTint)
            statGauge(icon: "memorychip", value: systemStats.memUsedFraction,
                      text: "\(Int((systemStats.memUsedFraction * 100).rounded()))%", tint: .purple)
            VStack(alignment: .leading, spacing: 2) {
                Label(SystemStatsManager.rateString(systemStats.netDownBytesPerSec), systemImage: "arrow.down")
                Label(SystemStatsManager.rateString(systemStats.netUpBytesPerSec), systemImage: "arrow.up")
            }
            .font(.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(.white.opacity(0.7))
            Spacer(minLength: 0)
        }
    }

    private var cpuTint: Color {
        switch systemStats.cpuUsage {
        case ..<0.5: return .green
        case ..<0.8: return .orange
        default:     return .red
        }
    }

    private func statGauge(icon: String, value: Double, text: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(text)
                    .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                Capsule().fill(.white.opacity(0.15)).frame(width: 46, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule().fill(tint).frame(width: 46 * max(0, min(1, value)), height: 4)
                    }
            }
        }
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
                if let url = calendar.meetingURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("Join", systemImage: "video.fill")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(calendar.isImminent ? Color.green : Color.blue))
                    }
                    .buttonStyle(.plain)
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

    // MARK: - Wi-Fi strength (expanded row)

    @ViewBuilder
    private var wifiRow: some View {
        HStack(spacing: 6) {
            if wifi.isConnected {
                Image(systemName: "wifi", variableValue: wifi.quality)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(wifi.quality >= 0.4 ? .white : .orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(wifi.ssid ?? "Wi-Fi")
                        .font(.system(.caption2, design: .rounded).weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("\(wifi.qualityLabel) · \(wifi.rssi ?? 0) dBm")
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            } else {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
                Text("No Wi-Fi")
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    // MARK: - PHASE 4: Mic/camera (expanded row)

    /// Always available while the mic/camera module is on — a mirror is most
    /// useful *before* a call, when the camera isn't in use yet.
    private var cameraMirrorButton: some View {
        Button { CameraMirrorPresenter.show() } label: {
            HStack(spacing: 5) {
                Image(systemName: "video.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text("Mirror")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Capsule().fill(.white.opacity(0.10)))
        }
        .buttonStyle(.plain)
        .help("Open a camera mirror")
    }

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
                Spacer(minLength: 0)
                if clipboard.hasUnpinned {
                    Button { clipboard.clearUnpinned() } label: {
                        Text("Clear")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
            }

            if clipboard.items.isEmpty {
                Text("Nothing copied yet")
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
            } else {
                ForEach(clipboard.items) { item in
                    HStack(spacing: 6) {
                        Button {
                            clipboard.togglePin(item)
                        } label: {
                            Image(systemName: item.pinned ? "pin.fill" : "pin")
                                .font(.system(size: 9))
                                .foregroundStyle(item.pinned ? .yellow : .white.opacity(0.3))
                                .frame(width: 14)
                        }
                        .buttonStyle(.plain)
                        .help(item.pinned ? "Unpin" : "Pin")

                        Button {
                            clipboard.copy(item)
                        } label: {
                            HStack {
                                Text(truncate(item.text, to: 38))
                                    .font(.system(.caption2, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                if clipboard.flashID == item.id {
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.15), value: clipboard.flashID)
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

    // MARK: - Panel footer (settings + sports switch)

    private var panelFooter: some View {
        HStack(spacing: 10) {
            Button {
                SettingsWindowPresenter.show(sports: sports)
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)

            // Blackjack game.
            Button {
                BlackjackWindowPresenter.show()
            } label: {
                Image(systemName: "suit.spade.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)

            // Texas Hold'em poker.
            Button {
                HoldemWindowPresenter.show()
            } label: {
                Image(systemName: "suit.heart.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)

            // Minesweeper.
            Button {
                MinesweeperWindowPresenter.show()
            } label: {
                Image(systemName: "flag.checkered")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)

            // Chess.
            Button {
                ChessWindowPresenter.show()
            } label: {
                Image(systemName: "crown.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)





            Spacer(minLength: 0)

            Text("Sports")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
            Toggle("", isOn: Binding(
                get: { sports.isSportsEnabled },
                set: { sports.isSportsEnabled = $0 }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(.green)
        }
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

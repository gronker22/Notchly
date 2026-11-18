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
import UniformTypeIdentifiers
import os

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

    /// Hides the panel entirely while Notchly puts up a modal of its own (the
    /// file picker). The notch sits at .screenSaver level, so without this it
    /// paints over the modal — and the hover monitor can't collapse it, because
    /// mouse-moved events stop arriving during a modal run.
    @Published var isSuppressed: Bool = false
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

    @State private var sportsTab: SportsView.Tab = .live
    /// Whether the games drawer above the footer is open.
    @State private var showGames = false

    // Update availability — drives the banner at the top of the panel.
    @StateObject private var updater = UpdateChecker()

    // System HUD (volume / brightness) + notification mirroring
    @StateObject private var hud = SystemHUDManager()
    @StateObject private var notifications = NotificationWatcher()

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
        // Launch idle: hug the notch. `collapsedHasInfo` can't be read here, and
        // nothing is live a moment after launch anyway.
        _width = State(initialValue: geometry.collapsedIdleWidth)
        _height = State(initialValue: geometry.collapsedIdleHeight)
    }

    private var hasLiveScore: Bool {
        sports.isSportsEnabled && sports.liveGames.contains { $0.state == .live }
    }
    private var timerShowing: Bool { settings.showPomodoro && pomodoro.isRunning }
    private var timerLabel: some View {
        Text(pomodoro.remainingString)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .lineLimit(1)
            .contentTransition(.numericText(countsDown: true))
            .animation(.smooth(duration: 0.3), value: pomodoro.remainingString)
    }

    /// Is there any collapsed content worth widening the pill for?
    private var collapsedHasInfo: Bool {
        (settings.showPomodoro && pomodoro.isRunning)
            || (settings.showMediaAccess && (media.micActive || media.cameraActive))
            || (sports.isSportsEnabled && sports.liveGames.contains { $0.state == .live })
            || (settings.showNotifications && !notifications.banners.isEmpty)
    }

    /// Collapsed pill height: flush when idle, dropped a little when showing info.
    private var collapsedTargetHeight: CGFloat {
        collapsedHasInfo ? geometry.collapsedHeight : geometry.collapsedIdleHeight
    }

    /// Collapsed pill WIDTH. With nothing live, shrink back to the hardware
    /// notch so Notchly disappears into it instead of sitting as a visible bar
    /// across the menu bar.
    private var collapsedTargetWidth: CGFloat {
        (collapsedHasInfo || !settings.hugNotchWhenIdle)
            ? geometry.collapsedWidth
            : geometry.collapsedIdleWidth
    }

    /// Spring for the open/close size morph.
    ///
    /// `dampingFraction: 0.7` overshoots by a visible margin. On the collapsed
    /// pill that's a nice pop, but the open panel is ~520pt tall, so the same
    /// overshoot travels far enough to read as a wobble. `.smooth` is Apple's
    /// no-bounce spring; a touch of `extraBounce` keeps it from feeling inert.
    private var sizeSpring: Animation {
        .smooth(duration: 0.42, extraBounce: 0.04)
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

            // Volume / brightness HUD. Sits above everything and only while the
            // notch is collapsed — when the panel is open the user is already
            // looking at it, and a HUD over the content would just obscure it.
            if settings.showSystemHUD, !state.isExpanded, let event = hud.event {
                systemHUD(event)
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
            }

            if state.isDragTargeting { dropHighlight }
        }
        .animation(.smooth(duration: 0.25), value: hud.event)
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
                withAnimation(sizeSpring) {
                    height = expandedTargetHeight
                }
            }
        }
        .onAppear {
            // If the island was opened before this view existed (a drag at
            // launch, the debug pin), onChange never fires — sync it once here
            // so the bubble isn't left at pill size under expanded content.
            if ProcessInfo.processInfo.environment["NOTCHLY_OPEN_SETTINGS"] == "1" {
                SettingsWindowPresenter.show(sports: sports)   // debug: review Settings
            }
            if state.isExpanded {
                animate(to: true)
                nowPlaying.setActive(settings.showNowPlaying)
                wifi.setActive(settings.showSystemStats)
            }
            // Only start the managers for modules the user has enabled — a
            // disabled module then does zero polling (battery + declutter).
            if settings.showNowPlaying { nowPlaying.start() }
            if settings.showCalendar { calendar.start() }   // Pomodoro starts on user action.
            if settings.showMediaAccess { media.start() }
            if settings.showClipboard { clipboard.start() }
            if settings.showSystemStats { systemStats.start(); wifi.start() }
            if settings.showSystemHUD { hud.start() }
            if settings.showNotifications { notifications.start() }
            sports.start()                                   // has its own in-panel toggle
            // One quiet check a few seconds after launch; the banner only
            // appears if there's actually something newer.
            Task {
                try? await Task.sleep(for: .seconds(6))
                updater.check()
            }
        }
        // These two can be switched on from Settings while the notch is live,
        // so follow the toggle instead of only reading it at launch.
        .onChange(of: settings.showSystemHUD) { _, on in
            on ? hud.start() : hud.stop()
        }
        .onChange(of: settings.showNotifications) { _, on in
            on ? notifications.start() : notifications.stop()
        }
        // Drop the collapsed pill down only while there's info to show.
        .onChange(of: collapsedHasInfo) { _, _ in
            if !state.isExpanded {
                withAnimation(sizeSpring) {
                    height = collapsedTargetHeight
                    width = collapsedTargetWidth
                }
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
                // Scores live here: the right of the menu bar is crowded with
                // status icons, the left is usually just app menus.
                HStack(spacing: 5) {
                    Spacer(minLength: 0)
                    if hasLiveScore {
                        SportsTicker(sports: sports)
                    } else if timerShowing {
                        timerLabel
                    }
                }
                .frame(width: geometry.flankWidth)
                .padding(.trailing, 4)

                // Notch gap (empty — the physical camera housing).
                Color.clear.frame(width: geometry.notchGap)

                // RIGHT flank
                HStack(spacing: 5) {
                    if settings.showMediaAccess { collapsedMediaIndicator }
                    // A score takes the left flank, so the timer moves over.
                    if hasLiveScore && timerShowing { timerLabel }
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
        // With nothing live the pill shrinks back to the hardware notch, so the
        // flank content would paint outside it — hide it along with the width.
        .opacity(state.isExpanded || (!collapsedHasInfo && settings.hugNotchWhenIdle) ? 0 : 1)
        .animation(.easeInOut(duration: 0.15), value: state.isExpanded)
        .allowsHitTesting(false)
    }

    // MARK: - File shelf

    /// Shown over the whole island while files are dragged onto it.
    /// Smallest bubble that still fits the drop icon and its caption.
    static let minDropHeight: CGFloat = 150

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            // Near-opaque: a translucent overlay let the panel's own text show
            // through and collide with the "Drop to add" caption.
            .fill(Color(white: 0.11).opacity(0.96))
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
            // Sized to the bubble as it is right now, not to the panel's
            // 520pt maximum: the bubble is only as tall as its content (shorter
            // still with an empty shelf), so a full-height overlay put its icon
            // below the bubble's bottom edge and it got cut off.
            .frame(width: geometry.expandedWidth, height: max(height, Self.minDropHeight))
            .transition(.opacity)
    }

    @ViewBuilder
    private var shelfRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "tray.full.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Text("SHELF")
                    .font(.system(size: 9, design: .rounded).weight(.bold))
                    .kerning(0.6)
                    .foregroundStyle(.white.opacity(0.55))
                Spacer(minLength: 0)
                // Quick switch for drag-to-open, so it can be turned off
                // without a trip to Settings when it gets in the way.
                Button { settings.dragOpensShelf.toggle() } label: {
                    HStack(spacing: 3) {
                        Image(systemName: settings.dragOpensShelf
                              ? "arrow.down.to.line.compact" : "nosign")
                            .font(.system(size: 8, weight: .bold))
                        Text(settings.dragOpensShelf ? "Drag: On" : "Drag: Off")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(settings.dragOpensShelf
                                     ? Color(red: 0.35, green: 0.85, blue: 0.55)
                                     : .white.opacity(0.45))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(settings.dragOpensShelf
                        ? Color(red: 0.35, green: 0.85, blue: 0.55).opacity(0.15)
                        : Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help(settings.dragOpensShelf
                      ? "Dragging a file to the notch opens the shelf. Click to turn off."
                      : "Dragging files to the notch does nothing. Click to turn on.")

                Button { addFilesViaPanel() } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "plus")
                            .font(.system(size: 8, weight: .bold))
                        Text("Add")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(Color(red: 0.55, green: 0.78, blue: 1.0))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color(red: 0.55, green: 0.78, blue: 1.0).opacity(0.15)))
                }
                .buttonStyle(.plain)
                .help("Choose files to park on the shelf")

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
                // Drop target *inside* the open panel. Dragging to the very top
                // edge of the screen can trigger Mission Control, which flies
                // in above every window and eats the drag before any app sees
                // it — so the notch alone can't be the only way in.
                VStack(spacing: 3) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.35))
                    Text("Drop files here, or use Add")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.white.opacity(0.35))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.white.opacity(state.isDragTargeting ? 0.14 : 0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(.white.opacity(state.isDragTargeting ? 0.5 : 0.15))
                )
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    loadDroppedFiles(providers)
                    return true
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(shelf.items) { shelfChip($0) }
                    }
                    .padding(.top, 3)       // room for the remove badge
                    .padding(.trailing, 4)
                }
                .frame(height: 70)
            }
        }
    }

    /// Open panel route — always works, regardless of what the window server
    /// does with a drag near the top edge of the screen.
    private func addFilesViaPanel() {
        // Collapse first. The hover monitor is driven by mouse-moved events,
        // which stop being delivered to us while a modal panel is up — so the
        // island would stay expanded and, being at .screenSaver level, paint a
        // large black rectangle over the file picker.
        state.isExpanded = false
        state.isSuppressed = true

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Add to Shelf"
        panel.message = "Choose files to park on the Notchly shelf"

        // `begin` rather than `runModal`: a modal run loop would also freeze
        // the notch's own animations until the panel closed.
        panel.begin { response in
            Task { @MainActor in
                if response == .OK { FileShelf.shared.add(panel.urls) }
                state.isSuppressed = false
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// SwiftUI `onDrop` hands back item providers; resolve each to a file URL.
    private func loadDroppedFiles(_ providers: [NSItemProvider]) {
        dropLog.log("panel onDrop: \(providers.count) provider(s)")
        for provider in providers {
            // `loadObject(ofClass: URL.self)` silently yields nothing for some
            // sources, so fall back to decoding the raw file-url data.
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, err in
                    if let url {
                        Task { @MainActor in FileShelf.shared.add([url]) }
                    } else {
                        dropLog.log("loadObject(URL) failed: \(String(describing: err), privacy: .public)")
                    }
                }
            } else {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, err in
                    guard let data,
                          let str = String(data: data, encoding: .utf8),
                          let url = URL(string: str) else {
                        dropLog.log("fileURL data decode failed: \(String(describing: err), privacy: .public)")
                        return
                    }
                    Task { @MainActor in FileShelf.shared.add([url]) }
                }
            }
        }
    }

    private func shelfChip(_ item: FileShelf.Item) -> some View {
        VStack(spacing: 3) {
            Image(nsImage: shelf.icon(for: item))
                .resizable()
                .frame(width: 26, height: 26)
            Text(item.name)
                .font(.system(size: 9, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .frame(width: 78)
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

    /// Now Playing only earns its column when something is actually playing.
    /// Otherwise it reserved a 150pt-wide, ~200pt-tall block showing "Nothing
    /// playing" — the single biggest piece of dead space in the panel.
    private var showsNowPlayingColumn: Bool {
        settings.showNowPlaying && nowPlaying.hasTrack
    }

    @ViewBuilder
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Update banner — only present when there's genuinely a newer
            // release, so it can't become background noise.
            if settings.showUpdateBanner, let url = updater.updateURL {
                Button { NSWorkspace.shared.open(url) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color(red: 0.25, green: 0.82, blue: 0.52))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Update available")
                                .font(.system(size: 11, design: .rounded).weight(.semibold))
                                .foregroundStyle(.white)
                            Text(updater.status.isEmpty ? "A newer version of Notchly is ready"
                                                        : updater.status)
                                .font(.system(size: 9, design: .rounded))
                                .foregroundStyle(.white.opacity(0.55))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Text("Get it")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Capsule().fill(Color(red: 0.25, green: 0.82, blue: 0.52)))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(red: 0.25, green: 0.82, blue: 0.52).opacity(0.12))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // One single column. There used to be a tall Now Playing column
            // beside a shorter left column, and whenever the two differed in
            // height — music playing, sports switched off, modules disabled —
            // the shorter side left a dead band. A single stack cannot have
            // that mismatch at all, so the gap can't come back.
            // The calendar only takes space when there is an event to show;
            // "Nothing scheduled" used to hold half the row for no information.
            let showsCalendar = settings.showCalendar && calendar.hasEvent
            if settings.showPomodoro || showsCalendar {
                HStack(alignment: .center, spacing: 14) {
                    if settings.showPomodoro { pomodoroControls }
                    if settings.showPomodoro && showsCalendar {
                        Rectangle()
                            .fill(.white.opacity(0.12))
                            .frame(width: 1, height: 38)
                    }
                    if showsCalendar { calendarRow }
                    Spacer(minLength: 0)
                }
            }

            if settings.showMediaAccess { mediaAccessRow }
            if settings.showNotifications { notificationsRow }
            if settings.showSystemStats { systemStatsRow }
            if settings.showClipboard { clipboardList }
            if sports.isSportsEnabled { sportsSection }
            if showsNowPlayingColumn { nowPlayingBar }

            // File shelf — drag files onto the notch to park them.
            shelfRow

            // Always-visible footer: settings + the sports on/off switch, so
            // sports can be re-enabled even when its section is hidden.
            Rectangle().fill(.white.opacity(0.10)).frame(height: 1)
            panelFooter
        }
        .animation(.smooth(duration: 0.32), value: settings.sportsExpanded)
        .animation(.smooth(duration: 0.3), value: showsNowPlayingColumn)
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
        // The entire open panel accepts files, not just the shelf's own strip:
        // once the island is open, anywhere inside it should work.
        .onDrop(of: [.fileURL], isTargeted: Binding(
            get: { state.isDragTargeting },
            set: { state.isDragTargeting = $0 }
        )) { providers in
            loadDroppedFiles(providers)
            return true
        }
        .opacity(state.isExpanded ? 1 : 0)
        .animation(.easeInOut(duration: 0.18), value: state.isExpanded)
        .allowsHitTesting(state.isExpanded)
    }

    // MARK: - Sports (collapsed by default)

    /// A one-line header that expands into the full score list on click. The
    /// live count sits in the header so the section is worth opening — or
    /// obviously isn't — without opening it.
    private var sportsSection: some View {
        let liveCount = sports.liveGames.filter { $0.state == .live }.count
        let nothingOn = sports.liveGames.allSatisfy { $0.state == .final }
        let liveRed = Color(red: 1.0, green: 0.35, blue: 0.35)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Button { settings.sportsExpanded.toggle() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "sportscourt.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.6))
                        Text("SCORES")
                            .font(.system(size: 9, design: .rounded).weight(.bold))
                            .kerning(0.6)
                            .foregroundStyle(.white.opacity(0.55))

                        if liveCount > 0 {
                            HStack(spacing: 4) {
                                Circle().fill(liveRed).frame(width: 5, height: 5)
                                Text("\(liveCount) live")
                                    .font(.system(size: 9, design: .rounded).weight(.bold))
                                    .foregroundStyle(Color(red: 1.0, green: 0.45, blue: 0.45))
                            }
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(liveRed.opacity(0.14)))
                        } else if nothingOn && sportsTab == .live {
                            // The empty state lives here, on the header line,
                            // instead of spending two more rows underneath.
                            Text("No games on")
                                .font(.system(size: 10, design: .rounded))
                                .foregroundStyle(.white.opacity(0.35))
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if settings.sportsExpanded {
                    sportsTabPill("Live", .live)
                    sportsTabPill("Yesterday", .yesterday)
                }

                Button { settings.sportsExpanded.toggle() } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.4))
                        .rotationEffect(.degrees(settings.sportsExpanded ? 180 : 0))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(settings.sportsExpanded ? "Hide scores" : "Show scores")
            }

            if settings.sportsExpanded && !(nothingOn && sportsTab == .live) {
                SportsView(sports: sports, tab: $sportsTab)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func sportsTabPill(_ title: String, _ tab: SportsView.Tab) -> some View {
        let isOn = sportsTab == tab
        return Button { sportsTab = tab } label: {
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(isOn ? .black : .white.opacity(0.7))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(isOn ? Color.white : Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Now Playing (full-width bar)

    /// Artwork, text and transport on one line, with the scrubber beneath.
    /// Because it spans the panel it can't leave empty space beside anything.
    @ViewBuilder
    private var nowPlayingBar: some View {
        HStack(spacing: 11) {
            artworkView

            VStack(alignment: .leading, spacing: 3) {
                Text(nowPlaying.title)
                    .font(.system(size: 12, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !nowPlaying.artist.isEmpty {
                    Text(nowPlaying.artist)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                nowPlayingScrubber
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            transportControls
        }
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
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
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
            // Scrubber only. The volume slider was removed — system volume
            // already has the F-keys and now the notch's own HUD, so a second
            // control here was redundant and cost a whole row.
            Group {
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
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 1)
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

    // MARK: - System HUD (volume / brightness)

    private func systemHUD(_ event: SystemHUDManager.Event) -> some View {
        VStack(spacing: 7) {
            Image(systemName: event.muted ? event.kind.mutedIcon : event.kind.icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))

            // Level bar. The fill animates, the track doesn't, so repeated taps
            // on a volume key read as one continuous slide rather than steps.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18))
                    Capsule()
                        .fill(.white)
                        .frame(width: max(3, geo.size.width * (event.muted ? 0 : event.value)))
                }
            }
            .frame(width: 108, height: 5)
            .animation(.smooth(duration: 0.22), value: event.value)
            .animation(.smooth(duration: 0.22), value: event.muted)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .padding(.top, 4)
    }

    // MARK: - PHASE 3: Focus timer (expanded)

    /// Ring + time, with the controls beneath. Replaces the old single cramped
    /// row, which rebuilt its `Text` through `.id(tickToken)` every second — that
    /// tore the view down and rebuilt it, so nothing could ever animate and the
    /// digits visibly snapped. Now the label keeps its identity and transitions
    /// numerically, and the ring interpolates between ticks.
    @ViewBuilder
    private var pomodoroControls: some View {
        let isWork = pomodoro.phase == .work
        let tint: Color = isWork ? Color(red: 1.0, green: 0.45, blue: 0.35)
                                 : Color(red: 0.35, green: 0.85, blue: 0.55)

        HStack(spacing: 11) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.13), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: max(0.0001, pomodoro.progress))
                    .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    // One tick is one second, so a linear 1s interpolation makes
                    // the ring sweep continuously instead of jumping 1/60th.
                    .animation(.linear(duration: 1), value: pomodoro.progress)
                Image(systemName: isWork ? "brain.head.profile" : "cup.and.saucer.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                Text(isWork ? "Focus" : "Break")
                    .font(.system(size: 9, design: .rounded).weight(.bold))
                    .foregroundStyle(tint)
                    .textCase(.uppercase)
                    .kerning(0.6)
                    .fixedSize()

                Text(pomodoro.remainingString)
                    .font(.system(size: 19, design: .rounded).weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.smooth(duration: 0.3), value: pomodoro.remainingString)
                    .fixedSize()

                HStack(spacing: 6) {
                    timerButton(pomodoro.isRunning ? "pause.fill" : "play.fill",
                                filled: !pomodoro.isRunning, tint: tint) {
                        pomodoro.startPause()
                    }
                    timerButton("arrow.counterclockwise", filled: false, tint: tint) {
                        pomodoro.reset()
                    }
                    if !pomodoro.isRunning {
                        timerButton("minus", filled: false, tint: tint) { pomodoro.adjustMinutes(by: -5) }
                        timerButton("plus",  filled: false, tint: tint) { pomodoro.adjustMinutes(by: 5) }
                    }
                }
                .padding(.top, 1)
            }
        }
        .animation(.smooth(duration: 0.28), value: pomodoro.isRunning)
        .animation(.smooth(duration: 0.28), value: isWork)
    }

    private func timerButton(_ icon: String, filled: Bool, tint: Color,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(filled ? .black : .white.opacity(0.85))
                .frame(width: 20, height: 20)
                .background(
                    Circle().fill(filled ? AnyShapeStyle(tint)
                                         : AnyShapeStyle(.white.opacity(0.13)))
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - PHASE 3: Calendar event row (expanded)

    /// Mirrors the focus timer's shape — a coloured leading rail instead of the
    /// timer's ring, then label / title / action stacked the same way — so the
    /// two sit side by side as one row instead of two unrelated widgets.
    @ViewBuilder
    private var calendarRow: some View {
        let accent: Color = calendar.isImminent
            ? Color(red: 1.0, green: 0.62, blue: 0.24)
            : Color(red: 0.40, green: 0.64, blue: 1.0)

        HStack(spacing: 10) {
            // Event-colour rail, the way Calendar marks an event.
            Capsule()
                .fill(accent)
                .frame(width: 3)
                .frame(maxHeight: .infinity)
                .opacity(calendar.hasEvent ? 1 : 0.25)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(calendar.hasEvent ? "UP NEXT" : "CALENDAR")
                        .font(.system(size: 9, design: .rounded).weight(.bold))
                        .foregroundStyle(accent)
                        .kerning(0.6)
                        .fixedSize()
                    if calendar.hasEvent, let countdown = calendar.countdownString {
                        Text(countdown)
                            .font(.system(size: 9, design: .rounded).weight(.semibold).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.45))
                            .fixedSize()
                    }
                }

                if calendar.hasEvent, let title = calendar.nextEventTitle {
                    Text(title)
                        .font(.system(size: 13, design: .rounded).weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let url = calendar.meetingURL {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "video.fill")
                                    .font(.system(size: 8, weight: .bold))
                                Text("Join")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                            }
                            .foregroundStyle(.black)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Capsule().fill(accent))
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 1)
                    }
                } else {
                    Text("Nothing scheduled")
                        .font(.system(size: 13, design: .rounded).weight(.medium))
                        .foregroundStyle(.white.opacity(0.35))
                        .lineLimit(1)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .animation(.smooth(duration: 0.3), value: calendar.isImminent)
        .animation(.smooth(duration: 0.3), value: calendar.nextEventTitle)
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

    // MARK: - Notifications (expanded row)

    @ViewBuilder
    private var notificationsRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "bell.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Text("NOTIFICATIONS")
                    .font(.system(size: 9, design: .rounded).weight(.bold))
                    .kerning(0.6)
                    .foregroundStyle(.white.opacity(0.55))
                Spacer(minLength: 0)
                if !notifications.banners.isEmpty {
                    Button { notifications.clear() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                    .help("Clear")
                }
            }

            if let reason = notifications.unavailableReason {
                // Permission missing or Notification Center absent — say so and
                // offer the fix, rather than showing an empty box forever.
                VStack(alignment: .leading, spacing: 5) {
                    Text(reason)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        NotificationWatcher.requestAccessibility()
                        NSWorkspace.shared.open(Self.accessibilityURL)
                    } label: {
                        Text("Grant access")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Capsule().fill(.white.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }
            } else if notifications.banners.isEmpty {
                Text("Nothing recent.")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(notifications.banners) { banner in
                        HStack(alignment: .top, spacing: 7) {
                            Circle()
                                .fill(.white.opacity(0.35))
                                .frame(width: 4, height: 4)
                                .padding(.top, 5)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 5) {
                                    Text(banner.title)
                                        .font(.system(size: 11, design: .rounded).weight(.semibold))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    if !banner.app.isEmpty {
                                        Text(banner.app)
                                            .font(.system(size: 9, design: .rounded))
                                            .foregroundStyle(.white.opacity(0.4))
                                            .lineLimit(1)
                                    }
                                }
                                if !banner.body.isEmpty {
                                    Text(banner.body)
                                        .font(.system(size: 10, design: .rounded))
                                        .foregroundStyle(.white.opacity(0.6))
                                        .lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .animation(.smooth(duration: 0.3), value: notifications.banners)
            }
        }
    }

    static let accessibilityURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

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
        let floor = state.isDragTargeting ? Self.minDropHeight : geometry.collapsedHeight
        return min(geometry.expandedHeight, max(floor, h))
    }

    // MARK: - Panel footer (settings + sports switch)

    /// Each action gets its own colour so the row reads as distinct buttons
    /// rather than five interchangeable grey glyphs. Settings is split off to
    /// the left, since it's the one entry that isn't a game.
    private var panelFooter: some View {
        let gamesTint = Color(red: 0.76, green: 0.62, blue: 1.0)
        return VStack(alignment: .leading, spacing: 8) {
            // Games drawer: three unlabelled suit icons became one labelled
            // button that reveals named entries.
            if showGames {
                HStack(spacing: 8) {
                    gameChip("Blackjack", "suit.spade.fill",
                             Color(red: 0.55, green: 0.78, blue: 1.0)) { BlackjackWindowPresenter.show() }
                    gameChip("Hold'em", "suit.heart.fill",
                             Color(red: 1.0, green: 0.42, blue: 0.48)) { HoldemWindowPresenter.show() }
                    gameChip("Chess", "crown.fill", gamesTint) { ChessWindowPresenter.show() }
                    Spacer(minLength: 0)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            HStack(spacing: 8) {
                footerButton("gearshape.fill",
                             tint: Color(red: 0.64, green: 0.70, blue: 0.80),
                             help: "Settings") {
                    SettingsWindowPresenter.show(sports: sports)
                }

                Button { showGames.toggle() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "gamecontroller.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Games")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                        Image(systemName: "chevron.up")
                            .font(.system(size: 7, weight: .bold))
                            .rotationEffect(.degrees(showGames ? 180 : 0))
                    }
                    .foregroundStyle(gamesTint)
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(gamesTint.opacity(0.15)))
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
            }
        }
        .animation(.smooth(duration: 0.25), value: showGames)
    }

    private func gameChip(_ title: String, _ symbol: String, _ tint: Color,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 10, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.opacity(0.15)))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func footerButton(_ symbol: String, tint: Color, help: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(tint.opacity(0.15))
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func animate(to expanded: Bool) {
        let targetW = expanded ? geometry.expandedWidth : collapsedTargetWidth
        let targetH = expanded ? expandedTargetHeight : collapsedTargetHeight

        withAnimation(sizeSpring) {
            width = targetW
            height = targetH
        }
    }
}

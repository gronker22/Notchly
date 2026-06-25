//
//  NotchWindowController.swift
//  Notchly — Phase 1
//
//  Owns the borderless NSPanel that overlays the physical notch. The panel:
//    - is sized to the EXPANDED footprint and pinned flush to the top-center
//      of the notched screen (so the blob can grow without resizing the window),
//    - floats at .screenSaver level so it sits above normal windows,
//    - is excluded from Mission Control / window cycling / Exposé,
//    - hosts the SwiftUI NotchView and tracks hover via an NSTrackingArea on
//      its content view.
//

import AppKit
import SwiftUI

final class NotchWindowController {

    private var panel: NotchPanel!
    private let state = NotchState()
    private var geometry: NotchGeometry

    // Cursor-position hover poller (more reliable than NSTrackingArea for a
    // borderless panel floating over other apps).
    private var hoverTimer: Timer?

    init() {
        self.geometry = NotchGeometry.current()
        buildPanel()
    }

    // MARK: - Setup

    private func buildPanel() {
        let frame = geometry.panelFrame

        let panel = NotchPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.level = .screenSaver                 // above normal app windows
        panel.isOpaque = false
        panel.backgroundColor = .clear             // shape provides the black
        panel.hasShadow = false                    // flush with screen → no shadow (Phase 5 adds one when detached)
        panel.isMovable = false
        panel.ignoresMouseEvents = false

        // Keep it out of Mission Control / Exposé / window cycling, and let it
        // ride along across every Space.
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary
        ]
        panel.hidesOnDeactivate = false

        // SwiftUI content hosted inside a tracking-aware view.
        let root = NotchView(state: state, geometry: geometry)
        let hosting = TrackingHostingView(rootView: root, state: state, geometry: geometry)
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        self.panel = panel
    }

    // MARK: - Lifecycle

    func show() {
        panel.orderFrontRegardless()
        startHoverMonitoring()
    }

    // MARK: - Hover (cursor-position polling)

    private func startHoverMonitoring() {
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.updateHoverState()
        }
        RunLoop.main.add(t, forMode: .common)
        hoverTimer = t
    }

    private func updateHoverState() {
        // Don't auto-collapse while floating (Phase 5) or mid drag-to-dock (Phase 6).
        guard !state.isDetached, !state.isDragTargeting else { return }

        let mouse = NSEvent.mouseLocation            // screen coords, y-up
        let screenFrame = geometry.screen.frame

        // Generous trigger zone hugging the notch (top-center, near the camera).
        let triggerW = geometry.collapsedWidth + 120
        let triggerH = geometry.collapsedHeight + 16
        let trigger = CGRect(
            x: screenFrame.midX - triggerW / 2,
            y: screenFrame.maxY - triggerH,
            width: triggerW,
            height: triggerH
        )

        // Hysteresis: open from the small trigger zone, stay open until the
        // cursor leaves the whole bubble footprint (prevents edge flicker).
        let shouldExpand = state.isExpanded
            ? geometry.panelFrame.contains(mouse)
            : trigger.contains(mouse)

        if shouldExpand != state.isExpanded {
            state.isExpanded = shouldExpand
        }
    }

    /// Re-detects geometry and repositions when the screen setup changes.
    func repositionForCurrentScreen() {
        geometry = NotchGeometry.current()
        panel.setFrame(geometry.panelFrame, display: true)

        // Rebuild the hosted view against the new geometry.
        let root = NotchView(state: state, geometry: geometry)
        let hosting = TrackingHostingView(rootView: root, state: state, geometry: geometry)
        hosting.frame = NSRect(origin: .zero, size: geometry.panelFrame.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
    }
}

// MARK: - Panel subclass

/// A borderless panel that can still receive mouse-moved events while the app
/// is in the background (we're an accessory app and never become key).
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Tracking-aware hosting view

/// NSHostingView subclass that installs an NSTrackingArea so hover over the
/// panel toggles `NotchState.isExpanded`. The tracking area covers the full
/// content view; the SwiftUI layer decides what to draw.
final class TrackingHostingView<Content: View>: NSHostingView<Content> {
    private let state: NotchState
    private let geometry: NotchGeometry

    // PHASE 5: drag-to-detach bookkeeping.
    private var dragAccumulated: CGSize = .zero
    private let detachThreshold: CGFloat = 20

    init(rootView: Content, state: NotchState, geometry: NotchGeometry) {
        self.state = state
        self.geometry = geometry
        super.init(rootView: rootView)
        installPhase5Gestures()
        // PHASE 6: accept tab/window drags so we can dock to a screen half.
        registerForDraggedTypes([.URL, .fileURL, .string])
    }

    @available(*, unavailable)
    required init(rootView: Content) { fatalError("use init(rootView:state:geometry:)") }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: - PHASE 5: drag to detach + double-click to re-attach

    private func installPhase5Gestures() {
        let pan = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)

        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick(_:)))
        doubleClick.numberOfClicksRequired = 2
        addGestureRecognizer(doubleClick)
    }

    @objc private func handlePan(_ g: NSPanGestureRecognizer) {
        guard let window = self.window else { return }
        let t = g.translation(in: nil)

        switch g.state {
        case .began:
            dragAccumulated = .zero
        case .changed:
            // Move the window with the cursor. (AppKit y is up; pan translation
            // in a non-flipped view is also y-up, so this matches.)
            var origin = window.frame.origin
            origin.x += t.x
            origin.y += t.y
            window.setFrameOrigin(origin)
            g.setTranslation(.zero, in: nil)

            dragAccumulated.width += t.x
            dragAccumulated.height += t.y
            if !state.isDetached,
               hypot(dragAccumulated.width, dragAccumulated.height) > detachThreshold {
                detach()
            }
        default:
            break
        }
    }

    @objc private func handleDoubleClick(_ g: NSClickGestureRecognizer) {
        guard state.isDetached, let window = self.window else { return }
        reattach(window)
    }

    private func detach() {
        state.isDetached = true
        state.isExpanded = true       // HUD stays open while floating
        // Drop shadow is rendered by SwiftUI (NotchView) keyed off isDetached.
    }

    private func reattach(_ window: NSWindow) {
        let target = geometry.panelFrame
        state.isDetached = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.45
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            // Hover poller (in the controller) takes over collapse from here.
            self?.state.isExpanded = false
        })
    }

    // MARK: - PHASE 6: drag-to-dock destination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        state.isDragTargeting = true
        state.isExpanded = true          // expand the island to reveal zones
        updateDragHalf(sender)
        return .generic
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDragHalf(sender)
        return .generic
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        endDragTargeting()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let half: WindowDockManager.Half = (state.dragHalf == .right) ? .right : .left
        let ok = WindowDockManager.dock(to: half)
        endDragTargeting()
        return ok
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        endDragTargeting()
    }

    private func updateDragHalf(_ sender: NSDraggingInfo) {
        // draggingLocation is in window (bottom-left) coords; split on midX.
        let x = sender.draggingLocation.x
        state.dragHalf = (x < bounds.midX) ? .left : .right
    }

    private func endDragTargeting() {
        state.isDragTargeting = false
        state.dragHalf = nil
        if !state.isDetached {
            state.isExpanded = false
        }
    }
}

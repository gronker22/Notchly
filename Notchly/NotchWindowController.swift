//
//  NotchWindowController.swift
//  Notchly
//
//  Owns the borderless NSPanel that overlays the physical notch. The panel is
//  pinned flush to the top-center of the notched screen and floats above other
//  windows. Critically, it does NOT steal clicks from other apps: when collapsed
//  it sets `ignoresMouseEvents = true` so every click in its (invisible) footprint
//  passes straight through to whatever is underneath. Hover is detected purely
//  from the global cursor position, so it still expands without capturing events.
//

import AppKit
import SwiftUI
import Combine

final class NotchWindowController {

    private var panel: NotchPanel!
    private let state = NotchState()
    private var geometry: NotchGeometry

    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    init() {
        self.geometry = NotchGeometry.current()
        buildPanel()
        wireMouseInteraction()
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

        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = true        // never steal key/focus from other apps

        // Start collapsed → transparent to mouse events so it can't block other
        // apps' title bars, tabs, or window controls at the top of the screen.
        panel.ignoresMouseEvents = true

        // Out of Mission Control / Exposé / window cycling; rides across Spaces.
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary
        ]
        panel.hidesOnDeactivate = false

        let root = NotchView(state: state, geometry: geometry)
        let hosting = TrackingHostingView(rootView: root, state: state, geometry: geometry)
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        self.panel = panel
    }

    /// The panel only captures the mouse while the bubble is actually open (or a
    /// drag is being targeted). Otherwise it's click-through.
    private func wireMouseInteraction() {
        Publishers.CombineLatest(state.$isExpanded, state.$isDragTargeting)
            .receive(on: RunLoop.main)
            .sink { [weak self] expanded, dragging in
                self?.panel.ignoresMouseEvents = !(expanded || dragging)
            }
            .store(in: &cancellables)
    }

    // MARK: - Lifecycle

    func show() {
        panel.orderFrontRegardless()
        startHoverMonitoring()
    }

    // MARK: - Hover (passive mouse-moved monitors)

    /// Instead of polling the cursor 10×/second forever (which kept the CPU
    /// awake and defeated App Nap), we listen for mouse-moved events. The
    /// handlers only fire while the pointer actually moves; a still pointer costs
    /// nothing. A global monitor covers movement over other apps; a local one
    /// covers movement over our own (expanded) panel. `.mouseMoved` monitors do
    /// NOT require the Accessibility permission.
    private func startHoverMonitoring() {
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.updateHoverState()
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.updateHoverState()
            return event
        }
        updateHoverState()
    }

    private func updateHoverState() {
        // Leave it open while a drag-to-dock is in progress.
        guard !state.isDragTargeting else { return }

        let mouse = NSEvent.mouseLocation            // screen coords, y-up
        let screenFrame = geometry.screen.frame

        // Trigger zone = the notch center only (not the flanks, so hovering
        // menu-bar items beside the notch doesn't expand it), flush height so it
        // doesn't reach down into the browser tab strip.
        let triggerW = geometry.notchGap > 0 ? geometry.notchGap : geometry.collapsedWidth
        let triggerH = geometry.collapsedIdleHeight
        let trigger = CGRect(
            x: screenFrame.midX - triggerW / 2,
            y: screenFrame.maxY - triggerH,
            width: triggerW,
            height: triggerH
        )

        // While open, stay open only while the cursor is over the ACTUAL visible
        // bubble (full width × current content height), not the empty area below
        // it inside the fixed panel frame. A small bottom margin avoids flicker
        // right at the edge.
        let f = geometry.panelFrame
        let bubbleH = max(geometry.collapsedHeight, state.bubbleHeight) + 6
        let bubbleRect = CGRect(
            x: f.minX,
            y: f.maxY - bubbleH,
            width: f.width,
            height: bubbleH
        )

        let shouldExpand = state.isExpanded
            ? bubbleRect.contains(mouse)
            : trigger.contains(mouse)

        if shouldExpand != state.isExpanded {
            state.isExpanded = shouldExpand
        }
    }

    /// Re-detects geometry and repositions when the screen setup changes.
    func repositionForCurrentScreen() {
        geometry = NotchGeometry.current()
        panel.setFrame(geometry.panelFrame, display: true)

        let root = NotchView(state: state, geometry: geometry)
        let hosting = TrackingHostingView(rootView: root, state: state, geometry: geometry)
        hosting.frame = NSRect(origin: .zero, size: geometry.panelFrame.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
    }
}

// MARK: - Panel subclass

/// A borderless panel that never becomes key/main so it can't steal focus or
/// activation from the app the user is actually working in.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Hosting view (drag-to-dock destination)

/// NSHostingView subclass that accepts tab/window drags for the drag-to-dock
/// feature. (Hover is handled by the controller's cursor poll; there is no
/// drag-to-detach.)
final class TrackingHostingView<Content: View>: NSHostingView<Content> {
    private let state: NotchState
    private let geometry: NotchGeometry

    init(rootView: Content, state: NotchState, geometry: NotchGeometry) {
        self.state = state
        self.geometry = geometry
        super.init(rootView: rootView)
        registerForDraggedTypes([.URL, .fileURL, .string])
    }

    @available(*, unavailable)
    required init(rootView: Content) { fatalError("use init(rootView:state:geometry:)") }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // Only capture clicks over the ACTUAL visible bubble. The panel frame is
    // always the full expanded footprint, so without this a click in the empty
    // transparent area below a short bubble would be swallowed instead of passing
    // through to the app underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        // While a drag is targeting we want the whole surface to accept the drop.
        if state.isDragTargeting { return super.hitTest(point) }

        let visibleHeight = max(geometry.collapsedHeight, state.bubbleHeight) + 6
        // View is not flipped: y grows upward, bubble is anchored to the top.
        if point.y < bounds.height - visibleHeight { return nil }
        return super.hitTest(point)
    }

    // MARK: - Drag-to-dock destination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        state.isDragTargeting = true
        state.isExpanded = true
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
        let x = sender.draggingLocation.x
        state.dragHalf = (x < bounds.midX) ? .left : .right
    }

    private func endDragTargeting() {
        state.isDragTargeting = false
        state.dragHalf = nil
        state.isExpanded = false
    }
}

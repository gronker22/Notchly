//
//  NotchDropCatcher.swift
//  Notchly — the window that actually catches files dropped on the notch
//
//  Why this exists as its own window:
//
//  The main notch panel is click-through while collapsed (`ignoresMouseEvents
//  = true`) so it can't swallow clicks meant for the menu bar or the app
//  underneath. But AppKit builds the list of candidate drag destinations when
//  the drag *begins*, and a window that ignores mouse events is never in it.
//  So `draggingEntered` was never called, the drop fell through to whatever
//  was underneath — typically the browser, which just opened the file — and no
//  amount of flipping `ignoresMouseEvents` mid-drag could help, because by
//  then the destination list is already fixed.
//
//  So the drop target has to be a window that accepts mouse events for its
//  whole life. Making the *main* panel do that would reintroduce click
//  stealing, which is the single most common complaint about notch apps. The
//  way out is a second, tiny panel covering only the physical notch — the
//  camera housing, where there is nothing to click anyway. It is interactive
//  from the moment it is created, so it is always a valid drag destination,
//  and it costs the user nothing because that region was dead space already.
//
//  On a display with no hardware notch there is no dead zone to hide in, and a
//  permanently interactive strip would eat real menu-bar clicks — so the
//  catcher simply isn't created there.
//

import AppKit
import UniformTypeIdentifiers
import os

/// Drag-and-drop onto a borderless accessory-app panel has a lot of ways to
/// silently do nothing, so this path logs every step. Watch it live with:
///
///     log stream --predicate 'subsystem == "com.notchly.Notchly"'
let dropLog = Logger(subsystem: "com.notchly.Notchly", category: "dropcatcher")

@MainActor
final class NotchDropCatcher {

    private var panel: NSPanel?
    private let state: NotchState
    /// Resting frame: exactly the notch, so no clicks are stolen.
    private var restingFrame: NSRect = .zero
    /// Frame used while a file drag is in flight — see `grow()`.
    private var dragFrame: NSRect = .zero
    private static var shared: NotchDropCatcher?

    init?(state: NotchState, geometry: NotchGeometry) {
        // No notch, no dead zone to borrow — don't risk the menu bar.
        guard geometry.hasHardwareNotch else { return nil }
        self.state = state
        build(geometry: geometry)
    }

    private func build(geometry: NotchGeometry) {
        let screen = geometry.screen.frame
        // Exactly the notch, no overhang. This window is permanently
        // interactive, so any pixel it covers beyond the housing would start
        // eating real clicks in the app underneath — the very thing the main
        // panel goes click-through to avoid.
        let w = geometry.notchWidth
        let h = Self.catcherHeight(geometry)
        let frame = NSRect(x: screen.midX - w / 2,
                           y: screen.maxY - h,
                           width: w,
                           height: h)

        let p = NSPanel(contentRect: frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        // Deliberately NOT .screenSaver (level 1000) like the main notch
        // panel. The window server does not offer drags to windows at those
        // very high levels, which is why no drag event ever reached the notch
        // no matter how the view was registered. .statusBar sits above normal
        // windows but inside the range that drag-destination resolution
        // searches. The window is transparent, so its level costs us nothing
        // visually — it only has to be reachable.
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isMovable = false
        p.becomesKeyOnlyIfNeeded = true
        p.ignoresMouseEvents = false          // the whole point
        p.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                .ignoresCycle, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false

        let view = DropCatcherView(state: state)
        view.frame = NSRect(origin: .zero, size: frame.size)
        view.autoresizingMask = [.width, .height]
        p.contentView = view

        panel = p
        restingFrame = frame
        // While a drag is in flight the catcher grows downward into the screen.
        // The notch alone is a 32pt-tall target pinned to the very top edge,
        // and reaching for it means dragging into the edge — which is where
        // macOS opens Mission Control to let you drop onto another Space. The
        // drag kept being taken away mid-flight (entered, then exited, never
        // dropped). Growing downward gives somewhere comfortable to release
        // that is nowhere near the edge.
        dragFrame = NSRect(x: screen.midX - 230,
                           y: screen.maxY - 300,
                           width: 460, height: 300)
        Self.shared = self
        dropLog.log("catcher built frame=\(NSStringFromRect(frame), privacy: .public) level=\(p.level.rawValue)")
    }

    /// The notch's own height — the dead region we're allowed to occupy.
    private static func catcherHeight(_ geometry: NotchGeometry) -> CGFloat {
        max(1, geometry.notchHeight)
    }

    func show() {
        panel?.orderFrontRegardless()
        startProximityMonitoring()
    }

    // MARK: - Open early, before the pointer reaches the top edge

    private var dragMonitor: Any?
    private var upMonitor: Any?
    /// Drag-pasteboard change count at the last mouse-up. The drag pasteboard
    /// keeps its contents after a drag ends, so "has files" alone would also be
    /// true while the user later drags a window or selects text.
    private var settledChangeCount = NSPasteboard(name: .drag).changeCount

    /// Reaching the notch means dragging into the top edge of the screen, where
    /// macOS opens Mission Control. So don't wait for the drag to arrive: when
    /// a *file* drag comes within reach, grow the drop area down to meet it.
    /// The drop can then be released a few hundred points below the edge.
    private func startProximityMonitoring() {
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerDragged() }
        }
        upMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.settledChangeCount = NSPasteboard(name: .drag).changeCount
                // Let performDragOperation run first if the drop was on us.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { Self.shrink() }
            }
        }
    }

    private func pointerDragged() {
        guard NotchSettings.shared.dragOpensShelf else { return }
        guard let panel, panel.frame != dragFrame else { return }
        let pb = NSPasteboard(name: .drag)
        // Only a drag that started since the last mouse-up, and carries files.
        guard pb.changeCount != settledChangeCount,
              pb.types?.contains(.fileURL) == true else { return }
        // Reach: the grown area plus a margin around it.
        let reach = dragFrame.insetBy(dx: -60, dy: -90)
        guard reach.contains(NSEvent.mouseLocation) else { return }
        dropLog.log("file drag approaching — opening drop area early")
        Self.grow()
    }

    /// Enlarge while a drag is in flight.
    fileprivate static func grow() {
        guard let me = shared, let panel = me.panel else { return }
        guard panel.frame != me.dragFrame else { return }
        panel.setFrame(me.dragFrame, display: false)
        dropLog.log("catcher grew to \(NSStringFromRect(me.dragFrame), privacy: .public)")
    }

    /// Back to covering just the notch, so ordinary clicks pass through again.
    fileprivate static func shrink() {
        guard let me = shared, let panel = me.panel else { return }
        guard panel.frame != me.restingFrame else { return }
        panel.setFrame(me.restingFrame, display: false)
        dropLog.log("catcher shrank back to the notch")
    }

    func reposition(geometry: NotchGeometry) {
        guard let panel, geometry.hasHardwareNotch else { return }
        let screen = geometry.screen.frame
        let w = geometry.notchWidth
        let h = Self.catcherHeight(geometry)
        panel.setFrame(NSRect(x: screen.midX - w / 2,
                              y: screen.maxY - h,
                              width: w, height: h),
                       display: true)
    }
}

// MARK: - The catching view

private final class DropCatcherView: NSView {

    private let state: NotchState

    /// Lit while a file drag is over the notch, so the drop target is visible
    /// instead of being an invisible guess.
    private var highlighted = false {
        didSet { needsDisplay = true }
    }

    init(state: NotchState) {
        self.state = state
        super.init(frame: .zero)
        wantsLayer = true
        // Finder and most apps put `public.file-url` on the pasteboard, but
        // some older sources only provide the legacy filenames type, so accept
        // both rather than silently refusing those drags.
        registerForDraggedTypes([.fileURL,
                                 NSPasteboard.PasteboardType("NSFilenamesPboardType")])
        dropLog.log("catcher view registered types=\(self.registeredDraggedTypes.map(\.rawValue).joined(separator: ","), privacy: .public)")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard highlighted else { return }
        NSColor.white.withAlphaComponent(0.22).setFill()
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2),
                             xRadius: 10, yRadius: 10)
        p.fill()
        NSColor.white.withAlphaComponent(0.7).setStroke()
        p.lineWidth = 2
        p.stroke()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    // No hitTest override on purpose. AppKit resolves a drag's destination view
    // *through* hitTest, so returning nil here would silently recreate the
    // original bug — the drop would find no target and fall through to the app
    // underneath. This view stays hit-testable; the area it covers is the
    // camera housing, where there is nothing to click.

    private func fileURLs(_ sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let types = sender.draggingPasteboard.types?.map(\.rawValue).joined(separator: ",") ?? "none"
        let urls = fileURLs(sender)
        dropLog.log("draggingEntered types=\(types, privacy: .public) urls=\(urls.count)")
        guard !urls.isEmpty else { return [] }
        // Switched off by the user: refuse the drag so nothing opens.
        guard MainActor.assumeIsolated({ NotchSettings.shared.dragOpensShelf }) else { return [] }
        highlighted = true
        // Give the user somewhere roomy to let go, away from the screen edge.
        NotchDropCatcher.grow()
        MainActor.assumeIsolated {
            state.isDragTargeting = true
            state.isExpanded = true      // open the island so the shelf is visible
        }
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropLog.log("draggingExited")
        highlighted = false
        // Deliberately does NOT shrink. The drag may still be in flight and
        // heading back; shrinking here would pull the target out from under it
        // exactly the way the top-edge gesture used to. It shrinks on
        // draggingEnded instead, which always fires when the drag finishes.
        MainActor.assumeIsolated { state.isDragTargeting = false }
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let ok = !fileURLs(sender).isEmpty
        dropLog.log("prepareForDragOperation -> \(ok)")
        return ok
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        dropLog.log("performDragOperation urls=\(urls.count)")
        highlighted = false
        guard !urls.isEmpty else { return false }
        MainActor.assumeIsolated {
            state.isDragTargeting = false
            FileShelf.shared.add(urls)
            state.isExpanded = true
            dropLog.log("shelf now holds \(FileShelf.shared.items.count) item(s)")
        }
        return true
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dropLog.log("draggingEnded")
        highlighted = false
        NotchDropCatcher.shrink()
        MainActor.assumeIsolated { state.isDragTargeting = false }
    }
}

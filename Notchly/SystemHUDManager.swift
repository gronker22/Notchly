//
//  SystemHUDManager.swift
//  Notchly — volume / brightness HUD in the notch
//
//  Watches the system's output volume and display brightness and publishes a
//  short-lived "HUD event" that the notch renders in place of macOS's own
//  centre-screen overlay.
//
//  Two different mechanisms, because Apple exposes these very differently:
//
//  * Volume — CoreAudio, fully public. We attach a property listener to the
//    default output device's virtual main volume (and its mute flag), so we get
//    told the instant it changes, by anything: the F-keys, Control Centre, a
//    third-party mixer. No polling, no permissions.
//
//  * Brightness — there is no public API at all. DisplayServices is a private
//    framework, so it's resolved at runtime with dlopen/dlsym rather than
//    linked: if a future macOS drops or renames the symbols, brightness simply
//    stops reporting instead of the app failing to launch. There's no change
//    notification either, so this one has to poll — only while the panel could
//    plausibly be reacting, and at a rate low enough not to matter.
//
//  Nothing here needs a TCC permission.
//

import Foundation
import Combine
import CoreAudio
import AppKit

@MainActor
final class SystemHUDManager: ObservableObject {

    enum Kind: Equatable {
        case volume, brightness, keyboardBacklight

        var icon: String {
            switch self {
            case .volume:            return "speaker.wave.2.fill"
            case .brightness:        return "sun.max.fill"
            case .keyboardBacklight: return "keyboard.fill"
            }
        }

        var mutedIcon: String {
            switch self {
            case .volume:            return "speaker.slash.fill"
            case .brightness:        return "sun.min.fill"
            case .keyboardBacklight: return "keyboard"
            }
        }
    }

    struct Event: Equatable {
        let kind: Kind
        let value: Double      // 0...1
        let muted: Bool
    }

    /// Non-nil while a HUD should be on screen. Cleared after `visibleFor`.
    @Published private(set) var event: Event?

    private var visibleFor: TimeInterval { NotchSettings.shared.hudDuration }
    private var hideTask: Task<Void, Never>?

    private var started = false
    private var listenerDevice: AudioDeviceID?
    private var brightnessTimer: Timer?
    private var lastBrightness: Double = -1

    /// Suppresses the very first callback: attaching a CoreAudio listener fires
    /// immediately, and flashing a HUD the moment the app launches looks broken.
    private var primed = false

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        attachVolumeListener()
        lastBrightness = Self.brightness() ?? -1
        startBrightnessPolling()
    }

    func stop() {
        guard started else { return }
        started = false
        detachVolumeListener()
        brightnessTimer?.invalidate()
        brightnessTimer = nil
        hideTask?.cancel()
        hideTask = nil
        event = nil
        primed = false
    }

    deinit {
        // Listener blocks capture nothing that needs main-actor teardown, and
        // CoreAudio tolerates removal from any thread.
        brightnessTimer?.invalidate()
    }

    // MARK: - Publishing

    private func publish(_ kind: Kind, _ value: Double, muted: Bool = false) {
        guard primed else { primed = true; return }
        let next = Event(kind: kind, value: min(1, max(0, value)), muted: muted)
        // CoreAudio sends two callbacks per change (the property and its
        // channels), so the identical event arrives twice. Keep the HUD alive
        // but don't re-publish — that would be a wasted SwiftUI invalidation.
        if event != next { event = next }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.visibleFor ?? 1.6))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.event = nil }
        }
    }

    // MARK: - Volume (CoreAudio, public API)

    /// 'vmvc' — kAudioHardwareServiceDeviceProperty_VirtualMainVolume. Spelled
    /// as the raw selector because the named constant lives in the deprecated
    /// AudioServices header.
    private static let virtualMainVolume = AudioObjectPropertySelector(0x766D7663)

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
        return err == noErr ? dev : nil
    }

    private static func volume(of device: AudioDeviceID) -> Double? {
        var addr = AudioObjectPropertyAddress(
            mSelector: virtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var v = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let err = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &v)
        return err == noErr ? Double(v) : nil
    }

    private static func isMuted(_ device: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var m = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let err = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &m)
        return err == noErr && m == 1
    }

    private func attachVolumeListener() {
        guard let dev = Self.defaultOutputDevice() else { return }
        listenerDevice = dev

        for selector in [Self.virtualMainVolume, kAudioDevicePropertyMute] {
            var addr = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(dev, &addr, DispatchQueue.main) { [weak self] _, _ in
                // Already on the main queue; hop to the actor to touch state.
                Task { @MainActor [weak self] in
                    guard let self, let d = self.listenerDevice else { return }
                    let v = Self.volume(of: d) ?? 0
                    self.publish(.volume, v, muted: Self.isMuted(d))
                }
            }
        }
    }

    private func detachVolumeListener() {
        listenerDevice = nil
    }

    // MARK: - Brightness (DisplayServices, private — resolved at runtime)

    private typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32

    /// Resolved once. `nil` means this macOS doesn't expose the symbol, in which
    /// case brightness is quietly skipped rather than breaking the whole HUD.
    private static let getBrightness: GetBrightnessFn? = {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            RTLD_NOW) else { return nil }
        guard let sym = dlsym(handle, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(sym, to: GetBrightnessFn.self)
    }()

    static var brightnessAvailable: Bool { getBrightness != nil }

    static func brightness() -> Double? {
        guard let fn = getBrightness else { return nil }
        var value: Float = 0
        let err = fn(CGMainDisplayID(), &value)
        return err == 0 ? Double(value) : nil
    }

    /// No change notification exists for brightness, so it must be sampled.
    /// 4 Hz is responsive enough that the HUD still feels immediate on a key
    /// press, while costing far less than a display-link or 30 Hz poll.
    private func startBrightnessPolling() {
        guard Self.brightnessAvailable else { return }
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sampleBrightness() }
        }
        RunLoop.main.add(t, forMode: .common)
        brightnessTimer = t
    }

    private func sampleBrightness() {
        guard let b = Self.brightness() else { return }
        defer { lastBrightness = b }
        guard lastBrightness >= 0 else { return }
        // Ignore sub-step jitter; one F-key press moves brightness ~1/16.
        guard abs(b - lastBrightness) > 0.005 else { return }
        publish(.brightness, b)
    }
}

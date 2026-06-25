//
//  MediaAccessMonitor.swift
//  Notchly — Phase 4: Mic / camera indicator
//
//  Detects when the microphone or camera is in use system-wide:
//   - Mic   → CoreAudio: default input device `kAudioDevicePropertyDeviceIsRunningSomewhere`
//             (block property listener for responsiveness + a 1s poll backstop).
//   - Camera → CoreMediaIO: any device's `kCMIODevicePropertyDeviceIsRunningSomewhere`.
//
//  ⚠️ App attribution caveat: macOS exposes *that* the mic/camera is on, but not
//  *which process* owns it via any public API. We use a best-effort heuristic:
//  the frontmost app at the moment usage begins (NSWorkspace). Good enough for a
//  glanceable indicator; treat the app name/icon as a hint, not ground truth.
//

import Foundation
import AppKit
import CoreAudio
import CoreMediaIO
import Combine

@MainActor
final class MediaAccessMonitor: ObservableObject {

    @Published private(set) var micActive = false
    @Published private(set) var cameraActive = false

    @Published private(set) var micApp: AppInfo?
    @Published private(set) var cameraApp: AppInfo?

    struct AppInfo {
        let name: String
        let icon: NSImage?
        let since: Date
    }

    private var pollTimer: Timer?
    private var micListenerDevice: AudioObjectID?

    // MARK: - Lifecycle

    func start() {
        installMicListener()

        // 1s poll: backstop for the mic listener + the camera (CoreMediaIO has
        // no equally convenient block API path here).
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
        poll()
    }

    // MARK: - Polling

    private func poll() {
        updateMic(isMicRunning())
        updateCamera(isCameraRunning())
    }

    private func updateMic(_ active: Bool) {
        guard active != micActive else { return }
        micActive = active
        micApp = active ? currentAppInfo() : nil
    }

    private func updateCamera(_ active: Bool) {
        guard active != cameraActive else { return }
        cameraActive = active
        cameraApp = active ? currentAppInfo() : nil
    }

    private func currentAppInfo() -> AppInfo {
        let app = NSWorkspace.shared.frontmostApplication
        return AppInfo(
            name: app?.localizedName ?? "An app",
            icon: app?.icon,
            since: Date()
        )
    }

    // MARK: - Mic (CoreAudio)

    private func defaultInputDevice() -> AudioObjectID? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID
        )
        return status == noErr ? deviceID : nil
    }

    private func isMicRunning() -> Bool {
        guard let device = defaultInputDevice() else { return false }
        var result: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &result)
        return status == noErr && result != 0
    }

    private func installMicListener() {
        guard let device = defaultInputDevice() else { return }
        micListenerDevice = device
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(device, &addr, DispatchQueue.main) { [weak self] _, _ in
            Task { @MainActor in self?.updateMic(self?.isMicRunning() ?? false) }
        }
    }

    // MARK: - Camera (CoreMediaIO)

    private func isCameraRunning() -> Bool {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, &dataSize
        ) == noErr, dataSize > 0 else { return false }

        let count = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
        var devices = [CMIOObjectID](repeating: 0, count: count)
        var used: UInt32 = dataSize
        guard CMIOObjectGetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, dataSize, &used, &devices
        ) == noErr else { return false }

        for device in devices {
            var running: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            var deviceAddr = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )
            if CMIOObjectGetPropertyData(device, &deviceAddr, 0, nil, size, &size, &running) == noErr,
               running != 0 {
                return true
            }
        }
        return false
    }

    deinit { pollTimer?.invalidate() }
}

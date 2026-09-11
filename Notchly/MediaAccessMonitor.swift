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

    // Mic listener bookkeeping so we can re-install on device change and remove
    // it cleanly (the old code leaked the block and went stale when the user
    // switched input devices, e.g. plugging in headphones).
    private var micListenerDevice: AudioObjectID?
    private var micListenerBlock: AudioObjectPropertyListenerBlock?
    private var defaultDeviceListenerBlock: AudioObjectPropertyListenerBlock?

    private var isRunningAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    // MARK: - Lifecycle

    func start() {
        if let device = defaultInputDevice() { installMicListener(on: device) }
        installDefaultDeviceListener()

        // 2s poll: backstop for the mic listener (which is already event-driven)
        // + the camera (CoreMediaIO has no equally convenient block API path).
        // 2s keeps the mic/camera indicator glanceable while halving the wakeups.
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
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

    private func installMicListener(on device: AudioObjectID) {
        removeMicListener()
        micListenerDevice = device
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.updateMic(self?.isMicRunning() ?? false) }
        }
        micListenerBlock = block
        AudioObjectAddPropertyListenerBlock(device, &isRunningAddress, DispatchQueue.main, block)
    }

    private func removeMicListener() {
        guard let device = micListenerDevice, let block = micListenerBlock else { return }
        AudioObjectRemovePropertyListenerBlock(device, &isRunningAddress, DispatchQueue.main, block)
        micListenerDevice = nil
        micListenerBlock = nil
    }

    /// Re-point the mic listener whenever the default input device changes, so
    /// mic detection keeps working after the user switches audio inputs.
    private func installDefaultDeviceListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let device = self.defaultInputDevice() { self.installMicListener(on: device) }
                self.updateMic(self.isMicRunning())
            }
        }
        defaultDeviceListenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddress, DispatchQueue.main, block)
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

    deinit {
        pollTimer?.invalidate()
        if let device = micListenerDevice, let block = micListenerBlock {
            AudioObjectRemovePropertyListenerBlock(device, &isRunningAddress, DispatchQueue.main, block)
        }
        if let block = defaultDeviceListenerBlock {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddress, DispatchQueue.main, block)
        }
    }
}

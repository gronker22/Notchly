//
//  CameraMirror.swift
//  Notchly — click the camera indicator to see yourself
//
//  A quick "how do I look before this call?" mirror. The capture session is
//  only created while the window is open, so the camera light is never on
//  unless you asked for it.
//

import SwiftUI
import AppKit
import AVFoundation
import Combine

@MainActor
final class CameraMirrorModel: ObservableObject {
    let session = AVCaptureSession()
    @Published private(set) var denied = false
    private var configured = false

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    if granted { self.configureAndRun() } else { self.denied = true }
                }
            }
        default:
            denied = true
        }
    }

    private func configureAndRun() {
        denied = false
        if !configured {
            configured = true
            session.beginConfiguration()
            session.sessionPreset = .high
            if let device = AVCaptureDevice.default(for: .video),
               let input = try? AVCaptureDeviceInput(device: device),
               session.canAddInput(input) {
                session.addInput(input)
            }
            session.commitConfiguration()
        }
        // startRunning() blocks — keep it off the main actor.
        let s = session
        Task.detached(priority: .userInitiated) { s.startRunning() }
    }

    func stop() {
        let s = session
        Task.detached(priority: .utility) { s.stopRunning() }
    }
}

/// Hosts the AVCaptureVideoPreviewLayer.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer = preview
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct CameraMirrorView: View {
    @StateObject private var model = CameraMirrorModel()

    var body: some View {
        ZStack {
            Color.black
            if model.denied {
                VStack(spacing: 10) {
                    Image(systemName: "video.slash.fill")
                        .font(.system(size: 30)).foregroundStyle(.white.opacity(0.7))
                    Text("Camera access is off")
                        .font(.system(.headline, design: .rounded)).foregroundStyle(.white)
                    Button("Open Privacy settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                .padding()
            } else {
                // Flip horizontally so it behaves like an actual mirror.
                CameraPreview(session: model.session)
                    .scaleEffect(x: -1, y: 1)
            }
        }
        .frame(minWidth: 320, minHeight: 240)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}

@MainActor
enum CameraMirrorPresenter {
    private static var window: NSWindow?

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: CameraMirrorView())
        let w = NSWindow(contentViewController: hosting)
        w.title = "Camera"
        w.styleMask = [.titled, .closable, .resizable]
        w.setContentSize(NSSize(width: 360, height: 270))
        w.center()
        w.isReleasedWhenClosed = false
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

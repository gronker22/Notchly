//
//  NetworkMonitor.swift
//  Notchly — Phase 4: Network speed
//
//  Polls per-interface byte counters once a second via getifaddrs (BSD if_data)
//  and publishes up/down rates. The collapsed ticker is shown only when traffic
//  exceeds 500 KB/s and fades out after 3s of sustained low traffic.
//

import Foundation
import Combine

@MainActor
final class NetworkMonitor: ObservableObject {

    /// Bytes/sec.
    @Published private(set) var uploadRate: Double = 0
    @Published private(set) var downloadRate: Double = 0
    /// Whether the collapsed pill should show the ticker.
    @Published private(set) var showsTicker = false

    private var timer: Timer?
    private var lastSample: (rx: UInt64, tx: UInt64)?
    private var lastSampleTime: Date?
    private var lowTrafficSince: Date?

    private let tickerThreshold: Double = 500 * 1024   // 500 KB/s
    private let idleFadeDelay: TimeInterval = 3

    // MARK: - Lifecycle

    func start() {
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        poll()
    }

    // MARK: - Formatted strings

    /// Expanded: "↑ 1.2 MB/s  ↓ 4.8 MB/s"
    var fullString: String {
        "↑ \(format(uploadRate))  ↓ \(format(downloadRate))"
    }

    /// Collapsed ticker: compact, e.g. "↑1.2 ↓4.8 MB/s"
    var tickerString: String {
        "↑\(formatShort(uploadRate)) ↓\(formatShort(downloadRate))"
    }

    // MARK: - Polling

    private func poll() {
        let now = Date()
        let sample = sampleCounters()

        defer {
            lastSample = sample
            lastSampleTime = now
        }

        guard let prev = lastSample, let prevTime = lastSampleTime else { return }
        let dt = now.timeIntervalSince(prevTime)
        guard dt > 0 else { return }

        // Guard against counter wrap/reset (interface down, etc.).
        let rxDelta = sample.rx >= prev.rx ? sample.rx - prev.rx : 0
        let txDelta = sample.tx >= prev.tx ? sample.tx - prev.tx : 0

        downloadRate = Double(rxDelta) / dt
        uploadRate = Double(txDelta) / dt

        let peak = max(uploadRate, downloadRate)
        if peak > tickerThreshold {
            lowTrafficSince = nil
            showsTicker = true
        } else {
            // Begin/continue the idle countdown.
            if lowTrafficSince == nil { lowTrafficSince = now }
            if let since = lowTrafficSince, now.timeIntervalSince(since) >= idleFadeDelay {
                showsTicker = false
            }
        }
    }

    // MARK: - Interface counters

    private func sampleCounters() -> (rx: UInt64, tx: UInt64) {
        var rx: UInt64 = 0
        var tx: UInt64 = 0

        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return (0, 0) }
        defer { freeifaddrs(ifaddrPtr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }

            guard let addr = p.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_LINK) else { continue }

            let flags = Int32(p.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0 else { continue }

            let name = String(cString: p.pointee.ifa_name)
            guard !name.hasPrefix("lo") else { continue }   // skip loopback

            if let data = p.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                rx += UInt64(data.pointee.ifi_ibytes)
                tx += UInt64(data.pointee.ifi_obytes)
            }
        }
        return (rx, tx)
    }

    // MARK: - Formatting

    private func format(_ bytesPerSec: Double) -> String {
        let (value, unit) = scaled(bytesPerSec)
        return String(format: "%.1f %@/s", value, unit)
    }

    private func formatShort(_ bytesPerSec: Double) -> String {
        let (value, _) = scaled(bytesPerSec)
        return String(format: "%.1f", value)
    }

    private func scaled(_ bytesPerSec: Double) -> (Double, String) {
        let kb = bytesPerSec / 1024
        if kb < 1000 { return (kb, "KB") }
        return (kb / 1024, "MB")
    }

    deinit { timer?.invalidate() }
}

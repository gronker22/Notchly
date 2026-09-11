//
//  WiFiMonitor.swift
//  Notchly — Wi-Fi strength
//
//  Reads the current Wi-Fi RSSI (signal strength) via CoreWLAN and derives a
//  0...1 quality plus a label. RSSI/tx-rate work without extra permission; the
//  SSID may be nil on macOS 14+ without Location access, in which case we just
//  show "Wi-Fi".
//

import Foundation
import CoreWLAN
import Combine

@MainActor
final class WiFiMonitor: ObservableObject {

    @Published private(set) var rssi: Int? = nil     // dBm (negative)
    @Published private(set) var ssid: String? = nil
    @Published private(set) var txRate: Double = 0   // Mbps

    private let client = CWWiFiClient.shared()
    private var timer: Timer?
    private var active = false

    /// One-shot prime; the repeating poll runs only while the panel is open.
    func start() {
        poll()
    }

    /// Wi-Fi strength is only shown in the expanded panel, so only poll while
    /// it's open. Collapsed, we keep the last reading and stop waking CoreWLAN.
    func setActive(_ active: Bool) {
        guard active != self.active else { return }
        self.active = active
        if active {
            poll()
            let t = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.poll() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    private func poll() {
        guard let iface = client.interface(), iface.powerOn() else {
            rssi = nil; ssid = nil; txRate = 0
            return
        }
        let r = iface.rssiValue()
        rssi = r == 0 ? nil : r
        ssid = iface.ssid()
        txRate = iface.transmitRate()
    }

    var isConnected: Bool { rssi != nil }

    /// 0 (poor) … 1 (excellent), from ~ −90 dBm to −30 dBm.
    var quality: Double {
        guard let r = rssi else { return 0 }
        return min(1, max(0, Double(r + 90) / 60))
    }

    var qualityLabel: String {
        guard let r = rssi else { return "No Wi-Fi" }
        switch r {
        case (-55)...:  return "Excellent"
        case (-67)...:  return "Good"
        case (-75)...:  return "Fair"
        default:        return "Weak"
        }
    }

    deinit { timer?.invalidate() }
}

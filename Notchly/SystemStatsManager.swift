//
//  SystemStatsManager.swift
//  Notchly — System stats peek (CPU / memory / network)
//
//  A glanceable "mini Activity Monitor" for the notch. Reads host CPU load,
//  physical memory pressure, and aggregate network throughput via the Mach /
//  BSD APIs. Like Wi-Fi and Now Playing, it only polls while the panel is open
//  (see `setActive`) so a closed notch costs nothing.
//

import Foundation
import Combine
import Darwin

@MainActor
final class SystemStatsManager: ObservableObject {

    @Published private(set) var cpuUsage: Double = 0        // 0…1 (all cores combined)
    @Published private(set) var memUsedFraction: Double = 0 // 0…1
    @Published private(set) var memUsedGB: Double = 0
    @Published private(set) var memTotalGB: Double = 0
    @Published private(set) var netDownBytesPerSec: Double = 0
    @Published private(set) var netUpBytesPerSec: Double = 0

    private var timer: Timer?
    private var active = false

    // Deltas need a previous sample.
    private var prevCPUTicks: (used: UInt64, total: UInt64)?
    private var prevNet: (inB: UInt64, outB: UInt64, time: TimeInterval)?

    private let totalMemGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0

    func start() {
        memTotalGB = totalMemGB
        sample()   // prime, so first open shows something
    }

    /// Poll only while the expanded panel is visible.
    func setActive(_ active: Bool) {
        guard active != self.active else { return }
        self.active = active
        if active {
            sample()
            let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.sample() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else {
            timer?.invalidate()
            timer = nil
            // Reset deltas so a re-open computes a fresh rate rather than a spike.
            prevCPUTicks = nil
            prevNet = nil
        }
    }

    private func sample() {
        sampleCPU()
        sampleMemory()
        sampleNetwork()
    }

    // MARK: - CPU (host aggregate load)

    private func sampleCPU() {
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info_data_t()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }

        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)
        let used = user + system + nice
        let total = used + idle

        if let prev = prevCPUTicks {
            let dUsed = Double(used &- prev.used)
            let dTotal = Double(total &- prev.total)
            if dTotal > 0 { cpuUsage = max(0, min(1, dUsed / dTotal)) }
        }
        prevCPUTicks = (used, total)
    }

    // MARK: - Memory

    private func sampleMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }

        let pageSize = Double(vm_kernel_page_size)
        // "Used" ≈ Activity Monitor's Memory Used: active + wired + compressed.
        let usedBytes = (Double(stats.active_count) + Double(stats.wire_count)
                         + Double(stats.compressor_page_count)) * pageSize
        let totalBytes = Double(ProcessInfo.processInfo.physicalMemory)
        memUsedGB = usedBytes / 1_073_741_824.0
        memUsedFraction = totalBytes > 0 ? max(0, min(1, usedBytes / totalBytes)) : 0
    }

    // MARK: - Network (aggregate throughput across physical interfaces)

    private func sampleNetwork() {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return }
        defer { freeifaddrs(ifaddrPtr) }

        var inBytes: UInt64 = 0
        var outBytes: UInt64 = 0
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            let ifa = cur.pointee
            if let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK) {
                let name = String(cString: ifa.ifa_name)
                if !name.hasPrefix("lo") {  // skip loopback
                    if let dataPtr = ifa.ifa_data?.assumingMemoryBound(to: if_data.self) {
                        inBytes += UInt64(dataPtr.pointee.ifi_ibytes)
                        outBytes += UInt64(dataPtr.pointee.ifi_obytes)
                    }
                }
            }
            ptr = ifa.ifa_next
        }

        let now = Date().timeIntervalSince1970
        if let prev = prevNet {
            let dt = now - prev.time
            if dt > 0 {
                netDownBytesPerSec = max(0, Double(inBytes &- prev.inB) / dt)
                netUpBytesPerSec = max(0, Double(outBytes &- prev.outB) / dt)
            }
        }
        prevNet = (inBytes, outBytes, now)
    }

    // MARK: - Formatting helpers

    var cpuPercentString: String { "\(Int((cpuUsage * 100).rounded()))%" }
    var memString: String { String(format: "%.1f / %.0f GB", memUsedGB, memTotalGB) }

    static func rateString(_ bytesPerSec: Double) -> String {
        let kb = bytesPerSec / 1024
        if kb < 1 { return "0 KB/s" }
        if kb < 1024 { return String(format: "%.0f KB/s", kb) }
        return String(format: "%.1f MB/s", kb / 1024)
    }

    deinit { timer?.invalidate() }
}

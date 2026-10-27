import Darwin

/// Cumulative CPU ticks across all cores, as reported by the kernel.
struct CPUTicks: Equatable {
    var user: UInt32
    var system: UInt32
    var idle: UInt32
    var nice: UInt32
}

struct CPUUsage: Equatable {
    /// Fractions in 0...1.
    var user: Double
    var system: Double

    var total: Double { min(user + system, 1) }

    /// Usage over the interval between two tick snapshots. Tick counters are
    /// 32-bit and wrap, so deltas use wrapping subtraction.
    static func between(_ old: CPUTicks, _ new: CPUTicks) -> CPUUsage? {
        let user = UInt64(new.user &- old.user) + UInt64(new.nice &- old.nice)
        let system = UInt64(new.system &- old.system)
        let idle = UInt64(new.idle &- old.idle)
        let all = user + system + idle
        guard all > 0 else { return nil }
        return CPUUsage(user: Double(user) / Double(all), system: Double(system) / Double(all))
    }
}

/// Aggregate CPU load via `host_statistics(HOST_CPU_LOAD_INFO)`: one syscall per sample.
final class CPUSampler {
    private let host = mach_host_self()
    private var last: CPUTicks?

    init() {
        last = readTicks()
    }

    func sample() -> CPUUsage? {
        guard let ticks = readTicks() else { return nil }
        defer { last = ticks }
        guard let last else { return nil }
        return CPUUsage.between(last, ticks)
    }

    private func readTicks() -> CPUTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return CPUTicks(
            user: info.cpu_ticks.0,
            system: info.cpu_ticks.1,
            idle: info.cpu_ticks.2,
            nice: info.cpu_ticks.3
        )
    }
}

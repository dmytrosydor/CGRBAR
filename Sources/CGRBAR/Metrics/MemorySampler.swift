import Darwin
import Foundation

enum MemoryPressure: Int32 {
    case normal = 1
    case warning = 2
    case critical = 4
}

struct MemoryUsage: Equatable {
    var total: UInt64
    var app: UInt64
    var wired: UInt64
    var compressed: UInt64
    var pressure: MemoryPressure?

    /// Matches Activity Monitor's "Memory Used": app + wired + compressed.
    var used: UInt64 { app + wired + compressed }

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(Double(used) / Double(total), 1)
    }

    static func from(
        _ stats: vm_statistics64,
        pageSize: UInt64,
        total: UInt64,
        pressure: MemoryPressure?
    ) -> MemoryUsage {
        let internalPages = UInt64(stats.internal_page_count)
        let purgeablePages = UInt64(stats.purgeable_count)
        let appPages = internalPages > purgeablePages ? internalPages - purgeablePages : 0
        return MemoryUsage(
            total: total,
            app: appPages * pageSize,
            wired: UInt64(stats.wire_count) * pageSize,
            compressed: UInt64(stats.compressor_page_count) * pageSize,
            pressure: pressure
        )
    }
}

/// Memory usage via `host_statistics64(HOST_VM_INFO64)` plus the kernel pressure level.
final class MemorySampler {
    private let host = mach_host_self()
    private let total = ProcessInfo.processInfo.physicalMemory
    private let pageSize: UInt64

    init() {
        var size: vm_size_t = 0
        host_page_size(host, &size)
        pageSize = size > 0 ? UInt64(size) : 16384
    }

    func sample() -> MemoryUsage? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return MemoryUsage.from(stats, pageSize: pageSize, total: total, pressure: readPressure())
    }

    private func readPressure() -> MemoryPressure? {
        var level: Int32 = 0
        var length = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &length, nil, 0) == 0 else {
            return nil
        }
        return MemoryPressure(rawValue: level)
    }
}

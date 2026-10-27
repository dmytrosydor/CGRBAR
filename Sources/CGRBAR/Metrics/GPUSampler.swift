import Foundation
import IOKit

struct GPUUsage: Equatable {
    /// Fractions in 0...1.
    var device: Double
    var renderer: Double?
    var tiler: Double?
    var memoryInUse: UInt64?

    /// Parses the `PerformanceStatistics` dictionary published by the GPU driver.
    init?(statistics: [String: Any]) {
        func number(_ key: String) -> NSNumber? { statistics[key] as? NSNumber }
        func fraction(_ key: String) -> Double? {
            number(key).map { min(max($0.doubleValue / 100, 0), 1) }
        }

        guard let device = fraction("Device Utilization %") else { return nil }
        self.device = device
        renderer = fraction("Renderer Utilization %")
        tiler = fraction("Tiler Utilization %")
        memoryInUse = number("In use system memory")?.uint64Value
    }
}

/// GPU load read from the `IOAccelerator` service in the IORegistry. No root needed.
final class GPUSampler {
    private var service: io_service_t = IO_OBJECT_NULL

    deinit {
        if service != IO_OBJECT_NULL { IOObjectRelease(service) }
    }

    func sample() -> GPUUsage? {
        if service == IO_OBJECT_NULL {
            service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
            guard service != IO_OBJECT_NULL else { return nil }
        }
        guard
            let property = IORegistryEntryCreateCFProperty(
                service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue(),
            let statistics = property as? [String: Any]
        else {
            // The service may have gone away; look it up again next time.
            IOObjectRelease(service)
            service = IO_OBJECT_NULL
            return nil
        }
        return GPUUsage(statistics: statistics)
    }
}

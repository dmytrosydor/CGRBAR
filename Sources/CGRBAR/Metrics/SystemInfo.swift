import Foundation
import IOKit

/// Static hardware facts, read once for the panel header.
enum SystemInfo {
    static let summary: String = {
        var parts = [chipName]
        parts.append("\(ProcessInfo.processInfo.processorCount) CPU")
        if let gpuCores { parts.append("\(gpuCores) GPU") }
        parts.append("\(ProcessInfo.processInfo.physicalMemory >> 30) GB")
        return parts.joined(separator: " · ")
    }()

    private static var chipName: String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "Mac" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return "Mac" }
        return String(cString: buffer)
    }

    private static var gpuCores: Int? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return (value as? NSNumber)?.intValue
    }
}

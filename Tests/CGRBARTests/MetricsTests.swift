import Foundation
import Testing
@testable import CGRBAR

@Suite struct CPUUsageTests {
    @Test func computesFractionsFromTickDeltas() throws {
        let old = CPUTicks(user: 100, system: 50, idle: 800, nice: 0)
        let new = CPUTicks(user: 160, system: 70, idle: 900, nice: 20)
        let usage = try #require(CPUUsage.between(old, new))
        #expect(usage.user == 0.4)
        #expect(usage.system == 0.1)
        #expect(usage.total == 0.5)
    }

    @Test func handlesCounterWraparound() throws {
        let old = CPUTicks(user: .max - 9, system: 0, idle: 0, nice: 0)
        let new = CPUTicks(user: 10, system: 0, idle: 20, nice: 0)
        let usage = try #require(CPUUsage.between(old, new))
        #expect(usage.user == 0.5)
    }

    @Test func returnsNilWithoutElapsedTicks() {
        let ticks = CPUTicks(user: 1, system: 1, idle: 1, nice: 1)
        #expect(CPUUsage.between(ticks, ticks) == nil)
    }
}

@Suite struct MemoryUsageTests {
    @Test func matchesActivityMonitorFormula() {
        var stats = vm_statistics64()
        stats.internal_page_count = 1000
        stats.purgeable_count = 200
        stats.wire_count = 300
        stats.compressor_page_count = 100
        let usage = MemoryUsage.from(stats, pageSize: 16384, total: 4000 * 16384, pressure: .normal)
        #expect(usage.app == 800 * 16384)
        #expect(usage.used == 1200 * 16384)
        #expect(usage.fraction == 0.3)
    }

    @Test func clampsPurgeableAboveInternal() {
        var stats = vm_statistics64()
        stats.internal_page_count = 10
        stats.purgeable_count = 20
        let usage = MemoryUsage.from(stats, pageSize: 4096, total: 4096, pressure: nil)
        #expect(usage.app == 0)
    }
}

@Suite struct GPUUsageTests {
    @Test func parsesPerformanceStatistics() throws {
        let stats: [String: Any] = [
            "Device Utilization %": NSNumber(value: 58),
            "Renderer Utilization %": NSNumber(value: 57),
            "Tiler Utilization %": NSNumber(value: 9),
            "In use system memory": NSNumber(value: 984_760_320),
        ]
        let usage = try #require(GPUUsage(statistics: stats))
        #expect(usage.device == 0.58)
        #expect(usage.renderer == 0.57)
        #expect(usage.memoryInUse == 984_760_320)
    }

    @Test func requiresDeviceUtilization() {
        #expect(GPUUsage(statistics: ["Tiler Utilization %": NSNumber(value: 1)]) == nil)
    }
}

@Suite struct FormatTests {
    @Test func percent() {
        #expect(Format.percent(0.123) == "12%")
        #expect(Format.percent(1.5) == "100%")
        #expect(Format.percent(-1) == "0%")
    }

    @Test func number() {
        #expect(Format.number(0.604) == "60")
        #expect(Format.number(2) == "100")
    }

    @Test func bytes() {
        #expect(Format.bytes(10_952_166_605) == "10.2 GB")
        #expect(Format.bytes(512 * 1_048_576) == "512 MB")
        #expect(Format.gigabytes(4_509_715_660) == "4.2")
    }

    @Test func loadThresholds() {
        #expect(Load(0.5) == .normal)
        #expect(Load(0.7) == .high)
        #expect(Load(0.95) == .critical)
    }
}

@Suite struct HistoryTests {
    @Test func keepsOnlyTheNewestValues() {
        var history = History(capacity: 3)
        for value in [0.1, 0.2, 0.3, 0.4] { history.append(value) }
        #expect(history.values == [0.2, 0.3, 0.4])
    }
}

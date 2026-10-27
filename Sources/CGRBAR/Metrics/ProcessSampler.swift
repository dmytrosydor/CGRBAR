import Darwin

enum ProcessSort: String, CaseIterable {
    case cpu = "CPU"
    case memory = "Memory"
}

struct ProcessUsage: Identifiable, Equatable {
    let id: pid_t
    var name: String
    /// Share of one core, like Activity Monitor: 1.5 means 150%.
    var cpu: Double
    /// Physical footprint in bytes, the "Memory" column in Activity Monitor.
    var memory: UInt64
}

/// Per-process CPU and memory via `proc_pid_rusage`. Only meant to run while
/// the panel is open: one call per process, a few milliseconds per sample.
/// Processes owned by other users (root daemons) are not readable without
/// privileges and are skipped.
final class ProcessSampler {
    private var lastCPUTime: [pid_t: UInt64] = [:]
    private var names: [pid_t: String] = [:]
    private var latest: [ProcessUsage] = []
    private var lastSampleTime: UInt64 = 0
    private let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    func reset() {
        lastCPUTime.removeAll()
        names.removeAll()
        latest.removeAll()
        lastSampleTime = 0
    }

    /// The heaviest processes from the latest sample. Names are only looked up
    /// for these, not for every process.
    func top(by sort: ProcessSort, limit: Int) -> [ProcessUsage] {
        let sorted = switch sort {
        case .cpu: latest.sorted { $0.cpu > $1.cpu }
        case .memory: latest.sorted { $0.memory > $1.memory }
        }
        return sorted.prefix(limit).map { process in
            var process = process
            process.name = name(of: process.id)
            return process
        }
    }

    func sample() {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let elapsed = lastSampleTime > 0 ? Double(now - lastSampleTime) : 0
        lastSampleTime = now

        var pids = [pid_t](repeating: 0, count: 4096)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return }

        var cpuTimes: [pid_t: UInt64] = [:]
        cpuTimes.reserveCapacity(count)
        var result: [ProcessUsage] = []
        result.reserveCapacity(count)

        for pid in pids.prefix(min(count, pids.count)) where pid > 0 {
            var info = rusage_info_v2()
            let status = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
                }
            }
            guard status == 0 else { continue }

            // rusage times are in Mach absolute time units.
            let cpuTime = (info.ri_user_time + info.ri_system_time)
                * UInt64(timebase.numer) / UInt64(timebase.denom)
            cpuTimes[pid] = cpuTime

            var cpu = 0.0
            if elapsed > 0, let last = lastCPUTime[pid], cpuTime >= last {
                cpu = Double(cpuTime - last) / elapsed
            }
            result.append(ProcessUsage(id: pid, name: "", cpu: cpu, memory: info.ri_phys_footprint))
        }

        lastCPUTime = cpuTimes
        latest = result
        names = names.filter { cpuTimes[$0.key] != nil }
    }

    private func name(of pid: pid_t) -> String {
        if let name = names[pid] { return name }
        var buffer = [CChar](repeating: 0, count: 256)
        let name = proc_name(pid, &buffer, UInt32(buffer.count)) > 0
            ? String(cString: buffer)
            : "pid \(pid)"
        names[pid] = name
        return name
    }
}

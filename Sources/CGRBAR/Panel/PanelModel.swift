import AppKit
import Observation

/// State behind the popover panel. Only exists while the panel is open.
@MainActor
@Observable
final class PanelModel {
    var cpu: CPUUsage?
    var gpu: GPUUsage?
    var memory: MemoryUsage?
    var cpuHistory: [Double] = []
    var gpuHistory: [Double] = []
    var memoryHistory: [Double] = []
    var processes: [ProcessUsage] = []
    var processSort: ProcessSort = .cpu {
        didSet { onSortChange() }
    }
    var colorsByLoad = true
    var highThreshold = 0.7
    var criticalThreshold = 0.9
    var historyCapacity = 60

    @ObservationIgnored var onSortChange: () -> Void = {}
    @ObservationIgnored var onShowSettings: () -> Void = {}
    @ObservationIgnored var onQuit: () -> Void = {}

    let summary = SystemInfo.summary

    @ObservationIgnored private var apps: [pid_t: NSRunningApplication?] = [:]

    /// The app behind a process, if it is one. Cached, since rows re-render
    /// on every update.
    func app(for pid: pid_t) -> NSRunningApplication? {
        if let app = apps[pid] { return app }
        let app = NSRunningApplication(processIdentifier: pid)
        apps[pid] = app
        return app
    }

    func openActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Asks a regular app to quit, the same way the Dock does. Background
    /// processes are left alone.
    func quit(_ process: ProcessUsage) {
        NSRunningApplication(processIdentifier: process.id)?.terminate()
    }
}

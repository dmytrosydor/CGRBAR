import AppKit
import ServiceManagement

/// Owns the menu bar item: samples metrics on a timer, updates the readout and
/// keeps the dropdown menu up to date while it is open.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let settings: Settings
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    private let cpuSampler = CPUSampler()
    private let gpuSampler = GPUSampler()
    private let memorySampler = MemorySampler()

    private var cpu: CPUUsage?
    private var gpu: GPUUsage?
    private var memory: MemoryUsage?

    private var timer: Timer?
    private var isMenuOpen = false
    private let meter = MeterView()
    private var lastSummary = ""

    private let cpuItem = NSMenuItem()
    private let cpuDetailItem = NSMenuItem()
    private let gpuItem = NSMenuItem()
    private let gpuDetailItem = NSMenuItem()
    private let memoryItem = NSMenuItem()
    private let memoryDetailItem = NSMenuItem()
    private var metricItems: [Metric: NSMenuItem] = [:]
    private var intervalItems: [NSMenuItem] = []
    private let labelsItem = NSMenuItem(title: "Show Labels", action: #selector(toggleLabels), keyEquivalent: "")
    private let colorItem = NSMenuItem(title: "Color by Load", action: #selector(toggleColor), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")

    private static let meterPadding: CGFloat = 3
    private static let detailFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)

    init(settings: Settings) {
        self.settings = settings
        super.init()
        setUpMeter()
        buildMenu()
        statusItem.menu = menu
    }

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(screensDidSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screensDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        tick()
        scheduleTimer()
    }

    // MARK: - Sampling

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = settings.interval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Generous tolerance lets the system coalesce wakeups.
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        // Hidden metrics are only sampled while the menu shows them.
        cpu = cpuSampler.sample() ?? cpu
        gpu = settings.isShown(.gpu) || isMenuOpen ? gpuSampler.sample() : nil
        memory = settings.isShown(.memory) || isMenuOpen ? memorySampler.sample() : nil
        updateMeter()
        if isMenuOpen { updateDetails() }
    }

    @objc private func screensDidSleep() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func screensDidWake() {
        tick()
        scheduleTimer()
    }

    // MARK: - Menu bar readout

    private func setUpMeter() {
        guard let button = statusItem.button else { return }
        meter.frame = button.bounds
        meter.autoresizingMask = [.width, .height]
        meter.onWidthChange = { [weak self] width in
            self?.statusItem.length = ceil(width) + 2 * Self.meterPadding
        }
        button.addSubview(meter)
    }

    private func updateMeter() {
        let segments = settings.shownMetrics.map { metric in
            let fraction = fraction(of: metric)
            return MeterSegment(
                label: settings.showsLabels ? metric.label : nil,
                value: fraction.map(Format.number) ?? "–",
                load: settings.colorsByLoad ? fraction.map(Load.init) ?? .normal : .normal
            )
        }
        meter.update(segments)

        let summary = segments.map { [$0.label, $0.value].compactMap { $0 }.joined(separator: " ") }
            .joined(separator: ", ")
        if summary != lastSummary {
            lastSummary = summary
            statusItem.button?.setAccessibilityLabel(summary)
        }
    }

    private func fraction(of metric: Metric) -> Double? {
        switch metric {
        case .cpu: cpu?.total
        case .gpu: gpu?.device
        case .memory: memory?.fraction
        }
    }

    // MARK: - Menu

    private func buildMenu() {
        menu.delegate = self
        menu.autoenablesItems = false

        for item in [cpuItem, cpuDetailItem, gpuItem, gpuDetailItem, memoryItem, memoryDetailItem] {
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let metricsMenu = NSMenu()
        for metric in Metric.allCases {
            let item = NSMenuItem(title: metric.label, action: #selector(toggleMetric), keyEquivalent: "")
            item.target = self
            item.representedObject = metric.rawValue
            metricsMenu.addItem(item)
            metricItems[metric] = item
        }
        menu.addItem(submenu("Show in Menu Bar", metricsMenu))

        let intervalMenu = NSMenu()
        for interval in Settings.intervals {
            let item = NSMenuItem(title: "\(Int(interval)) s", action: #selector(selectInterval), keyEquivalent: "")
            item.target = self
            item.representedObject = interval
            intervalMenu.addItem(item)
            intervalItems.append(item)
        }
        menu.addItem(submenu("Update Every", intervalMenu))

        for item in [labelsItem, colorItem] {
            item.target = self
            menu.addItem(item)
        }

        // Login items need a real app bundle; hide the option for bare builds.
        if Bundle.main.bundlePath.hasSuffix(".app") {
            loginItem.target = self
            menu.addItem(loginItem)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit CGRBAR", action: #selector(NSApplication.terminate), keyEquivalent: "q")
        menu.addItem(quit)

        updateDetails()
        updateSettingsItems()
    }

    private func submenu(_ title: String, _ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        tick()
        updateSettingsItems()
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }

    private func updateDetails() {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        if let cpu {
            set(cpuItem, "CPU  \(Format.percent(cpu.total))")
            set(cpuDetailItem, "user \(Format.percent(cpu.user)) · system \(Format.percent(cpu.system)) · \(cores) cores", detail: true)
        } else {
            set(cpuItem, "CPU  –")
            set(cpuDetailItem, "\(cores) cores", detail: true)
        }

        if let gpu {
            set(gpuItem, "GPU  \(Format.percent(gpu.device))")
            var parts: [String] = []
            if let renderer = gpu.renderer { parts.append("renderer \(Format.percent(renderer))") }
            if let tiler = gpu.tiler { parts.append("tiler \(Format.percent(tiler))") }
            if let memory = gpu.memoryInUse { parts.append("memory \(Format.bytes(memory))") }
            set(gpuDetailItem, parts.joined(separator: " · "), detail: true)
        } else {
            set(gpuItem, "GPU  unavailable")
            set(gpuDetailItem, "", detail: true)
        }
        gpuDetailItem.isHidden = gpu == nil

        if let memory {
            set(memoryItem, "RAM  \(Format.bytes(memory.used)) of \(Format.bytes(memory.total)) · \(Format.percent(memory.fraction))")
            var parts = [
                "app \(Format.bytes(memory.app))",
                "wired \(Format.bytes(memory.wired))",
                "compressed \(Format.bytes(memory.compressed))",
            ]
            if let pressure = memory.pressure { parts.append("pressure \(pressure.name)") }
            set(memoryDetailItem, parts.joined(separator: " · "), detail: true)
        } else {
            set(memoryItem, "RAM  –")
            set(memoryDetailItem, "", detail: true)
        }
        memoryDetailItem.isHidden = memory == nil
    }

    private func set(_ item: NSMenuItem, _ title: String, detail: Bool = false) {
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: detail ? Self.detailFont : NSFont.menuFont(ofSize: 0),
            .foregroundColor: detail ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ])
    }

    private func updateSettingsItems() {
        let shown = settings.shownMetrics
        for (metric, item) in metricItems {
            let isOn = shown.contains(metric)
            item.state = isOn ? .on : .off
            // Keep at least one metric in the menu bar.
            item.isEnabled = !(isOn && shown.count == 1)
        }
        for item in intervalItems {
            item.state = item.representedObject as? TimeInterval == settings.interval ? .on : .off
        }
        labelsItem.state = settings.showsLabels ? .on : .off
        colorItem.state = settings.colorsByLoad ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    // MARK: - Actions

    @objc private func toggleMetric(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let metric = Metric(rawValue: raw) else { return }
        settings.setShown(metric, !settings.isShown(metric))
        settingsChanged()
    }

    @objc private func selectInterval(_ sender: NSMenuItem) {
        guard let interval = sender.representedObject as? TimeInterval else { return }
        settings.interval = interval
        scheduleTimer()
        settingsChanged()
    }

    @objc private func toggleLabels() {
        settings.showsLabels.toggle()
        settingsChanged()
    }

    @objc private func toggleColor() {
        settings.colorsByLoad.toggle()
        settingsChanged()
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
        updateSettingsItems()
    }

    private func settingsChanged() {
        tick()
        updateSettingsItems()
    }
}

private extension MemoryPressure {
    var name: String {
        switch self {
        case .normal: "normal"
        case .warning: "warning"
        case .critical: "critical"
        }
    }
}

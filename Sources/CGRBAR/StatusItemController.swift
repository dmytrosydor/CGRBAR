import AppKit
import ServiceManagement
import SwiftUI

/// Owns the menu bar item: samples metrics on a timer, updates the readout,
/// shows the panel on click and the settings menu on right-click.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate, NSPopoverDelegate {
    private let settings: Settings
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let settingsMenu = NSMenu()
    private let popover = NSPopover()

    private let cpuSampler = CPUSampler()
    private let gpuSampler = GPUSampler()
    private let memorySampler = MemorySampler()
    private let processSampler = ProcessSampler()

    private var cpu: CPUUsage?
    private var gpu: GPUUsage?
    private var memory: MemoryUsage?
    private var cpuHistory = History(capacity: StatusItemController.historyCapacity)
    private var gpuHistory = History(capacity: StatusItemController.historyCapacity)
    private var memoryHistory = History(capacity: StatusItemController.historyCapacity)

    private var timer: Timer?
    private let meter = MeterView()
    private var lastSummary = ""
    /// Exists only while the panel is open.
    private var panel: PanelModel?

    private var metricItems: [Metric: NSMenuItem] = [:]
    private var intervalItems: [NSMenuItem] = []
    private let labelsItem = NSMenuItem(title: "Show Labels", action: #selector(toggleLabels), keyEquivalent: "")
    private let colorItem = NSMenuItem(title: "Color by Load", action: #selector(toggleColor), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")

    private static let meterPadding: CGFloat = 3
    private static let historyCapacity = 60
    private static let processLimit = 6

    init(settings: Settings) {
        self.settings = settings
        super.init()
        setUpMeter()
        buildSettingsMenu()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
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
        // All three together cost about 20 µs, so they always run to keep the
        // panel's history complete.
        if let cpu = cpuSampler.sample() {
            self.cpu = cpu
            cpuHistory.append(cpu.total)
        }
        gpu = gpuSampler.sample()
        if let gpu { gpuHistory.append(gpu.device) }
        memory = memorySampler.sample()
        if let memory { memoryHistory.append(memory.fraction) }

        updateMeter()
        if panel != nil {
            processSampler.sample()
            updatePanel()
        }
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
        button.target = self
        button.action = #selector(buttonClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
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

    @objc private func buttonClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showSettingsMenu()
        } else {
            togglePanel()
        }
    }

    // MARK: - Panel

    private func togglePanel() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }

        let model = PanelModel()
        model.historyCapacity = Self.historyCapacity
        model.onSortChange = { [weak self] in self?.updatePanel() }
        model.onShowSettings = { [weak self] in self?.showSettingsMenu() }
        model.onQuit = { NSApp.terminate(nil) }
        panel = model

        processSampler.reset()
        processSampler.sample()
        updatePanel()

        let host = NSHostingController(rootView: PanelView(model: model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        // Per-process CPU needs two samples; take the second one quickly
        // instead of waiting a full interval.
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel != nil else { return }
                self.processSampler.sample()
                self.updatePanel()
            }
        }
    }

    private func updatePanel() {
        guard let panel else { return }
        panel.cpu = cpu
        panel.gpu = gpu
        panel.memory = memory
        panel.cpuHistory = cpuHistory.values
        panel.gpuHistory = gpuHistory.values
        panel.memoryHistory = memoryHistory.values
        panel.colorsByLoad = settings.colorsByLoad
        panel.processes = processSampler.top(by: panel.processSort, limit: Self.processLimit)
    }

    func popoverDidClose(_ notification: Notification) {
        // Drop the SwiftUI tree and process data, so a closed panel costs nothing.
        panel = nil
        popover.contentViewController = nil
        processSampler.reset()
    }

    // MARK: - Settings menu

    private func buildSettingsMenu() {
        settingsMenu.delegate = self
        settingsMenu.autoenablesItems = false

        let metricsMenu = NSMenu()
        for metric in Metric.allCases {
            let item = NSMenuItem(title: metric.label, action: #selector(toggleMetric), keyEquivalent: "")
            item.target = self
            item.representedObject = metric.rawValue
            metricsMenu.addItem(item)
            metricItems[metric] = item
        }
        settingsMenu.addItem(submenu("Show in Menu Bar", metricsMenu))

        let intervalMenu = NSMenu()
        for interval in Settings.intervals {
            let item = NSMenuItem(title: "\(Int(interval)) s", action: #selector(selectInterval), keyEquivalent: "")
            item.target = self
            item.representedObject = interval
            intervalMenu.addItem(item)
            intervalItems.append(item)
        }
        settingsMenu.addItem(submenu("Update Every", intervalMenu))

        for item in [labelsItem, colorItem] {
            item.target = self
            settingsMenu.addItem(item)
        }

        // Login items need a real app bundle; hide the option for bare builds.
        if Bundle.main.bundlePath.hasSuffix(".app") {
            loginItem.target = self
            settingsMenu.addItem(loginItem)
        }

        settingsMenu.addItem(.separator())
        settingsMenu.addItem(NSMenuItem(title: "Quit CGRBAR", action: #selector(NSApplication.terminate), keyEquivalent: "q"))
    }

    private func submenu(_ title: String, _ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func showSettingsMenu() {
        if popover.isShown {
            // From the panel's gear button: open at the pointer.
            settingsMenu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        } else if let button = statusItem.button {
            settingsMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateSettingsItems()
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
        updateMeter()
        updatePanel()
        updateSettingsItems()
    }
}

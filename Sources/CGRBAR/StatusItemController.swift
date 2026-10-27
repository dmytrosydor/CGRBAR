import AppKit
import SwiftUI

/// Owns the menu bar items: samples metrics on a timer, updates the readouts,
/// shows the panel on click and a quick menu on right-click.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate, NSPopoverDelegate {
    private let settings: Settings
    private let quickMenu = NSMenu()
    private let popover = NSPopover()
    private lazy var settingsWindow = SettingsWindowController(settings: settings, preview: preview)
    private let preview = MeterPreviewModel()

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
    private var timerInterval: TimeInterval = 0
    /// Exists only while the panel is open.
    private var panel: PanelModel?

    /// One combined item, or one item per metric.
    private var items: [StatusEntry] = []
    private var itemsLayout: [[Metric]] = []

    private var metricItems: [Metric: NSMenuItem] = [:]
    private var intervalItems: [NSMenuItem] = []

    private static let meterPadding: CGFloat = 3
    private static let historyCapacity = 60
    private static let processLimit = 6

    @MainActor
    private final class StatusEntry {
        let item: NSStatusItem
        let meter = MeterView()
        let metrics: [Metric]
        var summary = ""

        init(item: NSStatusItem, metrics: [Metric]) {
            self.item = item
            self.metrics = metrics
        }
    }

    init(settings: Settings) {
        self.settings = settings
        super.init()
        buildQuickMenu()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        settings.onChange = { [weak self] in self?.settingsChanged() }
    }

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(screensDidSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screensDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        rebuildItemsIfNeeded()
        tick()
        scheduleTimer()
    }

    // MARK: - Sampling

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = settings.interval
        timerInterval = interval
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
        // charts' history complete.
        if let cpu = cpuSampler.sample() {
            self.cpu = cpu
            cpuHistory.append(cpu.total)
        }
        gpu = gpuSampler.sample()
        if let gpu { gpuHistory.append(gpu.device) }
        memory = memorySampler.sample()
        if let memory { memoryHistory.append(memory.fraction) }

        updateMeters()
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

    // MARK: - Menu bar items

    /// Creates or removes status items when the combined/separate choice or
    /// the shown metrics change. Separate items keep their own autosave names,
    /// so positions picked with ⌘-drag survive restarts.
    private func rebuildItemsIfNeeded() {
        let shown = settings.shownMetrics
        let layout = settings.separateItems ? shown.map { [$0] } : [shown]
        guard layout != itemsLayout else { return }
        itemsLayout = layout

        if popover.isShown { popover.performClose(nil) }
        for entry in items { NSStatusBar.system.removeStatusItem(entry.item) }
        // macOS places each new item left of the existing ones, so create
        // them from the last to keep the chosen order left to right.
        items = layout.reversed().map { metrics in
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = metrics.count == 1 && settings.separateItems
                ? "cgrbar.\(metrics[0].rawValue)"
                : "cgrbar.combined"
            let entry = StatusEntry(item: item, metrics: metrics)
            if let button = item.button {
                entry.meter.frame = button.bounds
                entry.meter.autoresizingMask = [.width, .height]
                entry.meter.onWidthChange = { [weak item] width in
                    item?.length = ceil(width) + 2 * Self.meterPadding
                }
                button.addSubview(entry.meter)
                button.target = self
                button.action = #selector(buttonClicked)
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            }
            return entry
        }
    }

    private func updateMeters() {
        let layout = meterLayout
        for entry in items {
            let segments = entry.metrics.map(segment)
            entry.meter.update(segments, layout: layout)

            let summary = segments.map { "\($0.metric.label) \($0.value.map(Format.percent) ?? "unavailable")" }
                .joined(separator: ", ")
            if summary != entry.summary {
                entry.summary = summary
                entry.item.button?.setAccessibilityLabel(summary)
            }
        }
        if settingsWindow.isVisible {
            preview.segments = settings.shownMetrics.map(segment)
            preview.layout = layout
        }
    }

    private var meterLayout: MeterLayout {
        MeterLayout(size: settings.size, spacing: settings.spacing)
    }

    private func segment(for metric: Metric) -> MeterSegment {
        let value = fraction(of: metric)
        let base: MeterTint = settings.colorMode == .metric ? .metric(metric) : .primary
        var valueTint = base
        if settings.colorsByLoad, let value {
            switch settings.load(for: value) {
            case .normal: break
            case .high: valueTint = .high
            case .critical: valueTint = .critical
            }
        }
        return MeterSegment(
            metric: metric,
            style: settings.style(for: metric),
            value: value,
            history: history(of: metric),
            labelTint: base,
            valueTint: valueTint
        )
    }

    private func fraction(of metric: Metric) -> Double? {
        switch metric {
        case .cpu: cpu?.total
        case .gpu: gpu?.device
        case .memory: memory?.fraction
        }
    }

    private func history(of metric: Metric) -> [Double] {
        // Only the chart style draws history; skip copying it otherwise.
        guard settings.style(for: metric) == .chart || settingsWindow.isVisible else { return [] }
        return switch metric {
        case .cpu: cpuHistory.values
        case .gpu: gpuHistory.values
        case .memory: memoryHistory.values
        }
    }

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showQuickMenu(from: sender)
        } else {
            togglePanel(from: sender)
        }
    }

    // MARK: - Panel

    private func togglePanel(from button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }

        let model = PanelModel()
        model.historyCapacity = Self.historyCapacity
        model.onSortChange = { [weak self] in self?.updatePanel() }
        model.onShowSettings = { [weak self] in self?.openSettings() }
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
        panel.highThreshold = settings.highThreshold
        panel.criticalThreshold = max(settings.criticalThreshold, settings.highThreshold)
        panel.processes = processSampler.top(by: panel.processSort, limit: Self.processLimit)
    }

    func popoverDidClose(_ notification: Notification) {
        // Drop the SwiftUI tree and process data, so a closed panel costs nothing.
        panel = nil
        popover.contentViewController = nil
        processSampler.reset()
    }

    // MARK: - Settings

    private func openSettings() {
        if popover.isShown { popover.performClose(nil) }
        preview.segments = settings.shownMetrics.map(segment)
        preview.layout = meterLayout
        settingsWindow.show()
    }

    private func settingsChanged() {
        if settings.interval != timerInterval { scheduleTimer() }
        rebuildItemsIfNeeded()
        updateMeters()
        updatePanel()
    }

    // MARK: - Quick menu

    private func buildQuickMenu() {
        quickMenu.delegate = self
        quickMenu.autoenablesItems = false

        let metricsMenu = NSMenu()
        for metric in Metric.allCases {
            let item = NSMenuItem(title: metric.label, action: #selector(toggleMetric), keyEquivalent: "")
            item.target = self
            item.representedObject = metric.rawValue
            metricsMenu.addItem(item)
            metricItems[metric] = item
        }
        quickMenu.addItem(submenu("Show in Menu Bar", metricsMenu))

        let intervalMenu = NSMenu()
        for interval in Settings.intervals {
            let item = NSMenuItem(title: "\(Int(interval)) s", action: #selector(selectInterval), keyEquivalent: "")
            item.target = self
            item.representedObject = interval
            intervalMenu.addItem(item)
            intervalItems.append(item)
        }
        quickMenu.addItem(submenu("Update Every", intervalMenu))

        quickMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        quickMenu.addItem(settingsItem)
        quickMenu.addItem(NSMenuItem(title: "Quit CGRBAR", action: #selector(NSApplication.terminate), keyEquivalent: "q"))
    }

    private func submenu(_ title: String, _ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func showQuickMenu(from button: NSStatusBarButton) {
        quickMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    func menuWillOpen(_ menu: NSMenu) {
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
    }

    @objc private func toggleMetric(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let metric = Metric(rawValue: raw) else { return }
        settings.setShown(metric, !settings.isShown(metric))
    }

    @objc private func selectInterval(_ sender: NSMenuItem) {
        guard let interval = sender.representedObject as? TimeInterval else { return }
        settings.interval = interval
    }

    @objc private func showSettings() {
        openSettings()
    }
}

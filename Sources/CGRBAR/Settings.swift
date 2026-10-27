import Foundation
import Observation

enum Metric: String, CaseIterable, Identifiable {
    case cpu, gpu, memory

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "RAM"
        }
    }

    var symbolName: String {
        switch self {
        case .cpu: "cpu"
        case .gpu: "cube"
        case .memory: "memorychip"
        }
    }
}

/// How one metric is drawn in the menu bar.
enum MeterStyle: String, CaseIterable, Identifiable {
    /// Tiny label above the number.
    case stacked
    /// Just the number.
    case number
    /// SF Symbol next to the number.
    case icon
    /// A thin vertical level bar.
    case bar
    /// A small chart of recent values.
    case chart

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stacked: "Label + number"
        case .number: "Number"
        case .icon: "Icon + number"
        case .bar: "Bar"
        case .chart: "Chart"
        }
    }
}

enum MeterSize: String, CaseIterable, Identifiable {
    case small, medium, large

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum ColorMode: String, CaseIterable, Identifiable {
    /// Follows the menu bar text color.
    case monochrome
    /// Blue CPU, purple GPU, teal RAM.
    case metric

    var id: String { rawValue }

    var title: String {
        switch self {
        case .monochrome: "Monochrome"
        case .metric: "Color per metric"
        }
    }
}

/// User preferences, persisted in `UserDefaults`. Every change is saved
/// right away and reported through `onChange`.
@MainActor
@Observable
final class Settings {
    static let intervals: [TimeInterval] = [1, 2, 5, 10]

    var order: [Metric] { didSet { save() } }
    var shown: Set<Metric> { didSet { save() } }
    var styles: [Metric: MeterStyle] { didSet { save() } }
    var size: MeterSize { didSet { save() } }
    /// Gap between metrics, in points.
    var spacing: Double { didSet { save() } }
    var colorMode: ColorMode { didSet { save() } }
    var colorsByLoad: Bool { didSet { save() } }
    var highThreshold: Double { didSet { save() } }
    var criticalThreshold: Double { didSet { save() } }
    /// One menu bar item per metric instead of a single combined one.
    var separateItems: Bool { didSet { save() } }
    var interval: TimeInterval { didSet { save() } }

    @ObservationIgnored var onChange: () -> Void = {}
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var isLoading = true

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let order = (defaults.stringArray(forKey: "order") ?? []).compactMap(Metric.init(rawValue:))
        self.order = order.count == Metric.allCases.count ? order : Metric.allCases

        var shown: Set<Metric>
        if let stored = defaults.stringArray(forKey: "shown") {
            shown = Set(stored.compactMap(Metric.init(rawValue:)))
        } else {
            // Earlier versions stored one flag per metric.
            shown = Set(Metric.allCases.filter { defaults.object(forKey: "show.\($0.rawValue)") as? Bool ?? true })
        }
        self.shown = shown.isEmpty ? [.cpu] : shown

        // Earlier versions only had a labels on/off switch.
        let fallbackStyle: MeterStyle = defaults.object(forKey: "showsLabels") as? Bool == false ? .number : .stacked
        let storedStyles = defaults.dictionary(forKey: "styles") as? [String: String] ?? [:]
        styles = Dictionary(uniqueKeysWithValues: Metric.allCases.map { metric in
            (metric, storedStyles[metric.rawValue].flatMap(MeterStyle.init(rawValue:)) ?? fallbackStyle)
        })

        size = defaults.string(forKey: "size").flatMap(MeterSize.init(rawValue:)) ?? .medium
        spacing = defaults.object(forKey: "spacing") as? Double ?? 6
        colorMode = defaults.string(forKey: "colorMode").flatMap(ColorMode.init(rawValue:)) ?? .monochrome
        colorsByLoad = defaults.object(forKey: "colorsByLoad") as? Bool ?? true
        highThreshold = defaults.object(forKey: "highThreshold") as? Double ?? 0.7
        criticalThreshold = defaults.object(forKey: "criticalThreshold") as? Double ?? 0.9
        separateItems = defaults.bool(forKey: "separateItems")

        let interval = defaults.double(forKey: "interval")
        self.interval = Self.intervals.contains(interval) ? interval : 2

        isLoading = false
    }

    /// Shown metrics in display order.
    var shownMetrics: [Metric] { order.filter(shown.contains) }

    func style(for metric: Metric) -> MeterStyle {
        styles[metric] ?? .stacked
    }

    func isShown(_ metric: Metric) -> Bool {
        shown.contains(metric)
    }

    /// Shows or hides a metric, keeping at least one visible.
    func setShown(_ metric: Metric, _ isShown: Bool) {
        if isShown {
            shown.insert(metric)
        } else if shown.count > 1 {
            shown.remove(metric)
        }
    }

    func load(for fraction: Double) -> Load {
        Load(fraction, high: highThreshold, critical: max(criticalThreshold, highThreshold))
    }

    func resetAppearance() {
        order = Metric.allCases
        styles = Dictionary(uniqueKeysWithValues: Metric.allCases.map { ($0, .stacked) })
        size = .medium
        spacing = 6
        colorMode = .monochrome
        colorsByLoad = true
        highThreshold = 0.7
        criticalThreshold = 0.9
        separateItems = false
    }

    private func save() {
        guard !isLoading else { return }
        defaults.set(order.map(\.rawValue), forKey: "order")
        defaults.set(Metric.allCases.filter(shown.contains).map(\.rawValue), forKey: "shown")
        defaults.set(Dictionary(uniqueKeysWithValues: styles.map { ($0.key.rawValue, $0.value.rawValue) }), forKey: "styles")
        defaults.set(size.rawValue, forKey: "size")
        defaults.set(spacing, forKey: "spacing")
        defaults.set(colorMode.rawValue, forKey: "colorMode")
        defaults.set(colorsByLoad, forKey: "colorsByLoad")
        defaults.set(highThreshold, forKey: "highThreshold")
        defaults.set(criticalThreshold, forKey: "criticalThreshold")
        defaults.set(separateItems, forKey: "separateItems")
        defaults.set(interval, forKey: "interval")
        onChange()
    }
}

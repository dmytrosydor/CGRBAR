import Foundation

enum Metric: String, CaseIterable {
    case cpu, gpu, memory

    var label: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "RAM"
        }
    }
}

/// User preferences, persisted in `UserDefaults`.
@MainActor
final class Settings {
    static let intervals: [TimeInterval] = [1, 2, 5, 10]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isShown(_ metric: Metric) -> Bool {
        bool("show.\(metric.rawValue)", default: true)
    }

    func setShown(_ metric: Metric, _ shown: Bool) {
        defaults.set(shown, forKey: "show.\(metric.rawValue)")
    }

    var shownMetrics: [Metric] { Metric.allCases.filter(isShown) }

    var interval: TimeInterval {
        get {
            let value = defaults.double(forKey: "interval")
            return Self.intervals.contains(value) ? value : 2
        }
        set { defaults.set(newValue, forKey: "interval") }
    }

    var showsLabels: Bool {
        get { bool("showsLabels", default: true) }
        set { defaults.set(newValue, forKey: "showsLabels") }
    }

    var colorsByLoad: Bool {
        get { bool("colorsByLoad", default: true) }
        set { defaults.set(newValue, forKey: "colorsByLoad") }
    }

    private func bool(_ key: String, default value: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? value
    }
}

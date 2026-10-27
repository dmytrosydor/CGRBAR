import Foundation

enum Load: Equatable {
    case normal, high, critical

    init(_ fraction: Double) {
        switch fraction {
        case 0.9...: self = .critical
        case 0.7...: self = .high
        default: self = .normal
        }
    }
}

enum Format {
    /// "12%". Input is a fraction in 0...1.
    static func percent(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }

    /// Percent padded to three digits with figure spaces, so the menu bar
    /// text keeps a fixed width as values change.
    static func paddedPercent(_ fraction: Double) -> String {
        let text = percent(fraction)
        let padding = max(0, 4 - text.count)
        return String(repeating: "\u{2007}", count: padding) + text
    }

    /// "10.2 GB", using binary units like Activity Monitor.
    static func bytes(_ value: UInt64) -> String {
        let gib = Double(value) / 1_073_741_824
        if gib >= 1 { return String(format: "%.1f GB", gib) }
        return String(format: "%.0f MB", Double(value) / 1_048_576)
    }
}

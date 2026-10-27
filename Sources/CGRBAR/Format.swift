import Foundation

enum Load: Equatable {
    case normal, high, critical

    init(_ fraction: Double, high: Double = 0.7, critical: Double = 0.9) {
        if fraction >= critical {
            self = .critical
        } else if fraction >= high {
            self = .high
        } else {
            self = .normal
        }
    }
}

enum Format {
    /// "12%". Input is a fraction in 0...1.
    static func percent(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }

    /// "12", for the menu bar where space is tight.
    static func number(_ fraction: Double) -> String {
        String(Int((min(max(fraction, 0), 1) * 100).rounded()))
    }

    /// "10.2" in GiB, for lists that print the unit once.
    static func gigabytes(_ value: UInt64) -> String {
        String(format: "%.1f", Double(value) / 1_073_741_824)
    }

    /// "10.2 GB", using binary units like Activity Monitor.
    static func bytes(_ value: UInt64) -> String {
        let gib = Double(value) / 1_073_741_824
        if gib >= 1 { return String(format: "%.1f GB", gib) }
        return String(format: "%.0f MB", Double(value) / 1_048_576)
    }
}

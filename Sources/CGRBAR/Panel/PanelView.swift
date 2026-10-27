import SwiftUI

struct PanelView: View {
    @Bindable var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            // Each section reads only its own data, so a tick re-renders the
            // sections that changed instead of the whole panel.
            CPUSection(model: model)
            GPUSection(model: model)
            MemorySection(model: model)

            ProcessList(model: model)

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 310)
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("CGRBAR").font(.headline)
                Text(model.summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.onShowSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
        }
    }

    private var footer: some View {
        HStack {
            Button {
                model.openActivityMonitor()
            } label: {
                Label("Activity Monitor", systemImage: "waveform.path.ecg")
            }
            Spacer()
            Button("Quit") { model.onQuit() }
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Sections

private struct CPUSection: View {
    let model: PanelModel

    var body: some View {
        MetricCard(
            title: "CPU",
            value: model.cpu?.total,
            accessory: nil,
            history: model.cpuHistory,
            capacity: model.historyCapacity,
            tint: model.tint(.blue, model.cpu?.total)
        ) {
            if let cpu = model.cpu {
                Text("user \(Format.percent(cpu.user)) · system \(Format.percent(cpu.system))")
            }
        }
    }
}

private struct GPUSection: View {
    let model: PanelModel

    var body: some View {
        MetricCard(
            title: "GPU",
            value: model.gpu?.device,
            accessory: model.gpu?.memoryInUse.map(Format.bytes),
            history: model.gpuHistory,
            capacity: model.historyCapacity,
            tint: model.tint(.purple, model.gpu?.device)
        ) {
            if let gpu = model.gpu {
                Text(detail(gpu))
            } else {
                Text("Not available")
            }
        }
    }

    private func detail(_ gpu: GPUUsage) -> String {
        var parts: [String] = []
        if let renderer = gpu.renderer { parts.append("renderer \(Format.percent(renderer))") }
        if let tiler = gpu.tiler { parts.append("tiler \(Format.percent(tiler))") }
        return parts.joined(separator: " · ")
    }
}

private struct MemorySection: View {
    let model: PanelModel

    var body: some View {
        MetricCard(
            title: "Memory",
            pressure: model.memory?.pressure,
            value: model.memory?.fraction,
            accessory: model.memory.map { Format.bytes($0.used) },
            history: model.memoryHistory,
            capacity: model.historyCapacity,
            tint: model.tint(.teal, model.memory?.fraction)
        ) {
            if let memory = model.memory {
                Text("app \(Format.gigabytes(memory.app)) · wired \(Format.gigabytes(memory.wired)) · compressed \(Format.gigabytes(memory.compressed)) GB")
            }
        }
    }
}

// MARK: - Metric card

private struct MetricCard<Detail: View>: View {
    let title: String
    var pressure: MemoryPressure? = nil
    let value: Double?
    let accessory: String?
    let history: [Double]
    let capacity: Int
    let tint: Color
    @ViewBuilder let detail: Detail

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                // Only worth showing when the system is short on memory.
                if let pressure, pressure != .normal { PressureBadge(pressure: pressure) }
                Spacer()
                if let accessory {
                    Text(accessory)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
                Text(value.map(Format.percent) ?? "–")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }

            Chart(values: history, capacity: capacity, tint: tint)
                .frame(height: 34)

            detail
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
    }
}

private struct Chart: View {
    let values: [Double]
    let capacity: Int
    let tint: Color

    var body: some View {
        ZStack {
            Sparkline(values: values, capacity: capacity, closed: true)
                .fill(LinearGradient(
                    colors: [tint.opacity(0.35), tint.opacity(0.02)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
            Sparkline(values: values, capacity: capacity, closed: false)
                .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}

/// Recent samples, newest on the right edge, scaled to 0...1.
private struct Sparkline: Shape {
    let values: [Double]
    let capacity: Int
    let closed: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        let step = rect.width / CGFloat(max(capacity - 1, 1))
        let startX = rect.maxX - CGFloat(values.count - 1) * step

        func point(_ index: Int) -> CGPoint {
            let value = min(max(values[index], 0), 1)
            return CGPoint(x: startX + CGFloat(index) * step, y: rect.maxY - CGFloat(value) * rect.height)
        }

        path.move(to: point(0))
        for index in values.indices.dropFirst() {
            path.addLine(to: point(index))
        }
        if closed {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: startX, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

private struct PressureBadge: View {
    let pressure: MemoryPressure

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: .capsule)
    }

    private var label: String {
        switch pressure {
        case .normal: "normal"
        case .warning: "high pressure"
        case .critical: "critical"
        }
    }

    private var color: Color {
        switch pressure {
        case .normal: .green
        case .warning: .orange
        case .critical: .red
        }
    }
}

// MARK: - Processes

private struct ProcessList: View {
    @Bindable var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Top Processes")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Sort", selection: $model.processSort) {
                    ForEach(ProcessSort.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }

            VStack(spacing: 1) {
                ForEach(model.processes) { process in
                    ProcessRow(process: process, sort: model.processSort, app: model.app(for: process.id)) {
                        model.quit(process)
                    }
                }
            }
        }
    }
}

private struct ProcessRow: View {
    let process: ProcessUsage
    let sort: ProcessSort
    let app: NSRunningApplication?
    let onQuit: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            if let icon = app?.icon {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            } else {
                Image(systemName: "gearshape")
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 16)
            }
            Text(app?.localizedName ?? process.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if isHovered, app != nil {
                Button(action: onQuit) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Quit \(app?.localizedName ?? process.name)")
            } else {
                Text(value)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6))
        .onHover { isHovered = $0 }
    }

    private var value: String {
        switch sort {
        case .cpu: String(format: "%.1f%%", process.cpu * 100)
        case .memory: Format.bytes(process.memory)
        }
    }
}

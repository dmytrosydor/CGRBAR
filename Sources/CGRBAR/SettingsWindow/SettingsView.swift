import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: Settings
    let preview: MeterPreviewModel

    var body: some View {
        TabView {
            MenuBarPane(settings: settings, preview: preview)
                .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
            GeneralPane(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            AboutPane()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480)
    }
}

// MARK: - Menu Bar

private struct MenuBarPane: View {
    @Bindable var settings: Settings
    let preview: MeterPreviewModel

    var body: some View {
        Form {
            Section {
                MeterPreview(segments: preview.segments, layout: preview.layout)
                    .frame(height: 26)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 8))
            } footer: {
                Text("Live preview of the menu bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Metrics") {
                ForEach(Array(settings.order.enumerated()), id: \.element) { index, metric in
                    MetricRow(settings: settings, metric: metric, index: index)
                }
            }

            Section("Look") {
                Picker("Size", selection: $settings.size) {
                    ForEach(MeterSize.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                LabeledContent("Spacing") {
                    HStack {
                        Slider(value: $settings.spacing, in: 2...16, step: 1)
                        Text("\(Int(settings.spacing)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }

                Picker("Colors", selection: $settings.colorMode) {
                    ForEach(ColorMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                Toggle("Separate item for each metric", isOn: $settings.separateItems)
                if settings.separateItems {
                    Text("Hold ⌘ and drag an item to move it around the menu bar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Load colors") {
                Toggle("Highlight high load", isOn: $settings.colorsByLoad)
                ThresholdSlider(title: "Orange from", value: $settings.highThreshold, range: 0.5...0.95)
                    .disabled(!settings.colorsByLoad)
                ThresholdSlider(title: "Red from", value: $settings.criticalThreshold, range: 0.6...1)
                    .disabled(!settings.colorsByLoad)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Reset to Defaults") { settings.resetAppearance() }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.highThreshold) { _, high in
            // Red never starts below orange.
            if settings.criticalThreshold < high { settings.criticalThreshold = high }
        }
        .onChange(of: settings.criticalThreshold) { _, critical in
            if settings.highThreshold > critical { settings.highThreshold = critical }
        }
    }
}

private struct MetricRow: View {
    @Bindable var settings: Settings
    let metric: Metric
    let index: Int

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(
                get: { settings.isShown(metric) },
                set: { settings.setShown(metric, $0) }
            )) {
                Label(metric.label, systemImage: metric.symbolName)
            }
            .toggleStyle(.checkbox)
            // The last visible metric can't be hidden.
            .disabled(settings.isShown(metric) && settings.shown.count == 1)

            Spacer()

            Picker("Style", selection: Binding(
                get: { settings.style(for: metric) },
                set: { settings.styles[metric] = $0 }
            )) {
                ForEach(MeterStyle.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()

            ControlGroup {
                Button { move(by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0)
                    .help("Move left")
                Button { move(by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(index == settings.order.count - 1)
                    .help("Move right")
            }
            .fixedSize()
        }
    }

    private func move(by offset: Int) {
        var order = settings.order
        order.swapAt(index, index + offset)
        settings.order = order
    }
}

private struct ThresholdSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range, step: 0.05)
                Text(Format.percent(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }
}

// MARK: - General

private struct GeneralPane: View {
    @Bindable var settings: Settings
    @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    /// Login items need a real app bundle.
    private let isBundled = Bundle.main.bundlePath.hasSuffix(".app")

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchesAtLogin)
                    .disabled(!isBundled)
                    .onChange(of: launchesAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }

                Picker("Update every", selection: $settings.interval) {
                    ForEach(Settings.intervals, id: \.self) { Text("\(Int($0)) s").tag($0) }
                }
            } footer: {
                Text("Shorter intervals react faster and cost a little more energy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        guard enabled != (service.status == .enabled) else { return }
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            launchesAtLogin = service.status == .enabled
        }
    }
}

// MARK: - About

private struct AboutPane: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("CGRBAR").font(.title2.weight(.semibold))
            Text("Version \(version)").foregroundStyle(.secondary)
            Text("CPU, GPU and RAM in your menu bar.")
            Link("github.com/dmytrosydor/CGRBAR", destination: URL(string: "https://github.com/dmytrosydor/CGRBAR")!)
            Text("MIT License").font(.caption).foregroundStyle(.secondary)
        }
        .padding(30)
        .frame(maxWidth: .infinity)
    }
}

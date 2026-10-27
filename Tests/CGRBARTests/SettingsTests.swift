import Foundation
import Testing
@testable import CGRBAR

@MainActor
@Suite struct SettingsTests {
    private func makeDefaults() -> UserDefaults {
        let name = "cgrbar.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func persistsChanges() {
        let defaults = makeDefaults()
        let settings = Settings(defaults: defaults)
        settings.styles[.gpu] = .chart
        settings.order = [.memory, .cpu, .gpu]
        settings.size = .large

        let reloaded = Settings(defaults: defaults)
        #expect(reloaded.style(for: .gpu) == .chart)
        #expect(reloaded.order == [.memory, .cpu, .gpu])
        #expect(reloaded.size == .large)
    }

    @Test func keepsAtLeastOneMetricShown() {
        let settings = Settings(defaults: makeDefaults())
        settings.setShown(.cpu, false)
        settings.setShown(.gpu, false)
        settings.setShown(.memory, false)
        #expect(settings.shownMetrics == [.memory])
    }

    @Test func migratesLabelsSwitch() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: "showsLabels")
        defaults.set(false, forKey: "show.gpu")
        let settings = Settings(defaults: defaults)
        #expect(settings.style(for: .cpu) == .number)
        #expect(settings.shownMetrics == [.cpu, .memory])
    }

    @Test func usesCustomThresholds() {
        let settings = Settings(defaults: makeDefaults())
        settings.highThreshold = 0.5
        settings.criticalThreshold = 0.6
        #expect(settings.load(for: 0.55) == .high)
        #expect(settings.load(for: 0.65) == .critical)
    }

    @Test func reportsChanges() {
        let settings = Settings(defaults: makeDefaults())
        var changes = 0
        settings.onChange = { changes += 1 }
        settings.spacing = 10
        #expect(changes == 1)
    }
}

import Foundation
import Testing
@testable import NotchApp

@MainActor
@Suite("Settings")
struct SettingsTests {
    @Test("Compact indicator defaults to reveal on hover and persists")
    func compactIndicatorPersistence() {
        let suiteName = "NotchAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = Settings(defaults: defaults)
        #expect(initial.compactIndicatorMode == .revealOnHover)

        initial.compactIndicatorMode = .alwaysShow
        #expect(Settings(defaults: defaults).compactIndicatorMode == .alwaysShow)
    }

    @Test("Unknown compact indicator values fall back safely")
    func unknownCompactIndicator() {
        let suiteName = "NotchAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("future-mode", forKey: "compactIndicatorMode")

        #expect(Settings(defaults: defaults).compactIndicatorMode == .revealOnHover)
    }
}

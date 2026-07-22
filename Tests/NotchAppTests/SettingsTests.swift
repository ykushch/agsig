import Foundation
import HerdrClient
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

    @Test("Preferred terminal defaults to automatic and persists")
    func preferredTerminalPersistence() {
        let suiteName = "NotchAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = Settings(defaults: defaults)
        #expect(initial.preferredTerminal == .automatic)

        initial.preferredTerminal = .iTerm2
        #expect(Settings(defaults: defaults).preferredTerminal == .iTerm2)
    }

    @Test("Custom terminal produces a preferred activation profile")
    func customTerminalProfile() {
        let suiteName = "NotchAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = Settings(defaults: defaults)
        settings.preferredTerminal = .custom
        settings.customTerminalAppName = "My Terminal"
        settings.customTerminalBundleID = "dev.example.terminal"

        #expect(settings.terminalProfiles == [TerminalProfile(
            id: "custom",
            displayName: "My Terminal",
            appName: "My Terminal",
            bundleIdentifiers: ["dev.example.terminal"])])
    }

    @Test("Legacy Ghostty display setting maps to preferred terminal display")
    func legacyGhosttyDisplaySetting() {
        let suiteName = "NotchAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("ghosttyDisplay", forKey: "displayPlacement")

        #expect(Settings(defaults: defaults).displayPlacement == .terminalDisplay)
    }
}

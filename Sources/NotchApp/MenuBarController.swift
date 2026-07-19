import AppKit
import SwiftUI

@MainActor
final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private let settings: Settings
    private let onSessionChange: () -> Void
    private let onToggleNotch: () -> Void

    init(settings: Settings, onSessionChange: @escaping () -> Void, onToggleNotch: @escaping () -> Void) {
        self.settings = settings
        self.onSessionChange = onSessionChange
        self.onToggleNotch = onToggleNotch
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "bell.badge", accessibilityDescription: "Notch Agent")
        let menu = NSMenu()
        let toggle = NSMenuItem(title: "Show / Hide Notch", action: #selector(toggleNotch), keyEquivalent: "")
        toggle.target = self; menu.addItem(toggle)
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self; menu.addItem(settingsItem)
        let accessibility = NSMenuItem(title: "Open Accessibility Settings…", action: #selector(openAccessibility), keyEquivalent: "")
        accessibility.target = self; menu.addItem(accessibility)
        menu.addItem(.separator())
        let provenance = NSMenuItem(title: Self.buildProvenanceTitle(), action: nil, keyEquivalent: "")
        provenance.isEnabled = false
        provenance.toolTip = Self.buildSourcePath()
        menu.addItem(provenance)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Notch Agent", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    func remove() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    @objc private func toggleNotch() { onToggleNotch() }

    @objc private func openAccessibility() {
        HotkeyMonitor.promptForAccessibility()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openSettings() {
        if let settingsWindow { settingsWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let view = SettingsView(settings: settings, onSessionChange: onSessionChange, availableSessions: Self.discoverSessions())
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Notch Agent Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    private static func discoverSessions() -> [String] {
        let base = NSString(string: "~/.config/herdr/sessions").expandingTildeInPath
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: base) else { return [] }
        return names.filter { name in
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: (base as NSString).appendingPathComponent(name), isDirectory: &directory) && directory.boolValue
        }.sorted()
    }

    private static func buildProvenanceTitle(bundle: Bundle = .main) -> String {
        let revision = bundle.object(forInfoDictionaryKey: "NotchAgentGitRevision") as? String
            ?? "development"
        let dirty = bundle.object(forInfoDictionaryKey: "NotchAgentGitDirty") as? Bool
            ?? false
        return "Build \(revision)\(dirty ? "-dirty" : "")"
    }

    private static func buildSourcePath(bundle: Bundle = .main) -> String? {
        bundle.object(forInfoDictionaryKey: "NotchAgentSourcePath") as? String
    }
}

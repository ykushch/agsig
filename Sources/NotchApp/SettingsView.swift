import SwiftUI

struct SettingsView: View {
    @Bindable var settings: Settings
    @Bindable var updates: UpdateChecker
    let onSessionChange: () -> Void
    let availableSessions: [String]

    var body: some View {
        Form {
            Picker("herdr session", selection: Binding(get: { settings.sessionName ?? "" }, set: { settings.sessionName = $0.isEmpty ? nil : $0; onSessionChange() })) {
                Text("Default / active").tag("")
                ForEach(availableSessions, id: \.self) { Text($0).tag($0) }
            }
            Toggle("Auto-expand when done", isOn: $settings.autoExpandOnDone)
            Toggle("Enable sounds", isOn: $settings.soundEnabled)
            Toggle("Respect Do Not Disturb", isOn: $settings.respectDND)
            Picker("Hotkey modifier", selection: $settings.hotkeyModifier) {
                ForEach(HotkeyModifier.allCases) { Text("\($0.displayName) (\($0.symbols))").tag($0) }
            }
            Picker("Pill display", selection: $settings.displayPlacement) {
                ForEach(DisplayPlacement.allCases) { Text($0.displayName).tag($0) }
            }
            Text(displayPlacementHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
            Section("Jump") {
                Picker("Terminal app", selection: $settings.preferredTerminal) {
                    ForEach(PreferredTerminal.allCases) { Text($0.displayName).tag($0) }
                }
                if settings.preferredTerminal == .custom {
                    TextField("Application name", text: $settings.customTerminalAppName)
                    TextField("Bundle identifier (optional)", text: $settings.customTerminalBundleID)
                }
                Text("Auto-detect uses a running terminal only when the choice is unambiguous.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Picker("Compact indicator", selection: $settings.compactIndicatorMode) {
                ForEach(CompactIndicatorMode.allCases) { Text($0.displayName).tag($0) }
            }
            Text("Reveal on hover keeps a minimal status line visible until you point at it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Launch at login", isOn: $settings.launchAtLogin)
            Section("Updates") {
                LabeledContent("Version", value: updates.currentVersionText)
                Toggle("Check for updates automatically", isOn: $settings.automaticUpdateChecks)
                HStack {
                    Text(updates.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Now", action: updates.checkNow)
                        .disabled(!updates.isSupported || updates.state == .checking)
                }
            }
            HStack {
                Text("Socket override")
                TextField("Auto-discover", text: Binding(get: { settings.socketPathOverride ?? "" }, set: { settings.socketPathOverride = $0.isEmpty ? nil : $0 }))
                    .onSubmit(onSessionChange)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 460, height: 640)
    }

    private var displayPlacementHelp: String {
        switch settings.displayPlacement {
        case .notchDisplay:
            "Uses the built-in notch when available. On non-notch Macs, the pill floats at the top center."
        case .activeDisplay:
            "Follows the display with keyboard focus. Display changes settle for a moment before the pill moves."
        case .terminalDisplay:
            "Uses the display containing the preferred terminal, falling back to the active display."
        }
    }
}

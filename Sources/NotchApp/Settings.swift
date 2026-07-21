import AppKit
import Observation

enum HotkeyModifier: String, CaseIterable, Identifiable {
    case controlOption, control, option, commandOption, commandControl, command
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .controlOption: "Control + Option"
        case .control: "Control"
        case .option: "Option"
        case .commandOption: "Command + Option"
        case .commandControl: "Command + Control"
        case .command: "Command"
        }
    }
    var symbols: String {
        switch self {
        case .controlOption: "⌃⌥"
        case .control: "⌃"
        case .option: "⌥"
        case .commandOption: "⌘⌥"
        case .commandControl: "⌘⌃"
        case .command: "⌘"
        }
    }
    var flags: NSEvent.ModifierFlags {
        switch self {
        case .controlOption: [.control, .option]
        case .control: .control
        case .option: .option
        case .commandOption: [.command, .option]
        case .commandControl: [.command, .control]
        case .command: .command
        }
    }
}

enum DisplayPlacement: String, CaseIterable, Identifiable {
    case notchDisplay
    case activeDisplay
    case ghosttyDisplay

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .notchDisplay: "Notch display"
        case .activeDisplay: "Active display"
        case .ghosttyDisplay: "Display with Ghostty"
        }
    }
}

enum CompactIndicatorMode: String, CaseIterable, Identifiable {
    case revealOnHover
    case alwaysShow

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .revealOnHover: "Reveal on hover"
        case .alwaysShow: "Always show"
        }
    }
}

@Observable @MainActor
final class Settings {
    private let defaults: UserDefaults
    var socketPathOverride: String? { didSet { defaults.set(socketPathOverride, forKey: Keys.socketPathOverride) } }
    var sessionName: String? { didSet { defaults.set(sessionName, forKey: Keys.sessionName) } }
    var autoExpandOnDone: Bool { didSet { defaults.set(autoExpandOnDone, forKey: Keys.autoExpandOnDone) } }
    var soundEnabled: Bool { didSet { defaults.set(soundEnabled, forKey: Keys.soundEnabled) } }
    var soundPack: String { didSet { defaults.set(soundPack, forKey: Keys.soundPack) } }
    var respectDND: Bool { didSet { defaults.set(respectDND, forKey: Keys.respectDND) } }
    var hotkeyModifier: HotkeyModifier { didSet { defaults.set(hotkeyModifier.rawValue, forKey: Keys.hotkeyModifier) } }
    var displayPlacement: DisplayPlacement { didSet { defaults.set(displayPlacement.rawValue, forKey: Keys.displayPlacement) } }
    var compactIndicatorMode: CompactIndicatorMode { didSet { defaults.set(compactIndicatorMode.rawValue, forKey: Keys.compactIndicatorMode) } }
    var launchAtLogin: Bool { didSet { defaults.set(launchAtLogin, forKey: Keys.launchAtLogin); LoginItem.setEnabled(launchAtLogin) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        socketPathOverride = defaults.string(forKey: Keys.socketPathOverride)
        sessionName = defaults.string(forKey: Keys.sessionName)
        autoExpandOnDone = defaults.object(forKey: Keys.autoExpandOnDone) as? Bool ?? false
        soundEnabled = defaults.object(forKey: Keys.soundEnabled) as? Bool ?? true
        soundPack = defaults.string(forKey: Keys.soundPack) ?? "default"
        respectDND = defaults.object(forKey: Keys.respectDND) as? Bool ?? true
        hotkeyModifier = HotkeyModifier(rawValue: defaults.string(forKey: Keys.hotkeyModifier) ?? "") ?? .controlOption
        displayPlacement = DisplayPlacement(
            rawValue: defaults.string(forKey: Keys.displayPlacement) ?? "") ?? .notchDisplay
        compactIndicatorMode = CompactIndicatorMode(
            rawValue: defaults.string(forKey: Keys.compactIndicatorMode) ?? "") ?? .revealOnHover
        launchAtLogin = defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false
    }

    func resolvedSocketPath() -> String? {
        if let path = socketPathOverride, !path.isEmpty { return path }
        if let sessionName, !sessionName.isEmpty {
            return NSString(string: "~/.config/herdr/sessions/\(sessionName)/herdr.sock").expandingTildeInPath
        }
        return nil
    }

    private enum Keys {
        static let socketPathOverride = "socketPathOverride"
        static let sessionName = "sessionName"
        static let autoExpandOnDone = "autoExpandOnDone"
        static let soundEnabled = "soundEnabled"
        static let soundPack = "soundPack"
        static let respectDND = "respectDND"
        static let hotkeyModifier = "hotkeyModifier"
        static let displayPlacement = "displayPlacement"
        static let compactIndicatorMode = "compactIndicatorMode"
        static let launchAtLogin = "launchAtLogin"
    }
}

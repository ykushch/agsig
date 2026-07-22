import Foundation

#if canImport(AppKit)
import AppKit
#endif

/// A macOS terminal application that can host an attached herdr client.
public struct TerminalProfile: Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
    public let appName: String
    public let bundleIdentifiers: [String]

    public init(
        id: String,
        displayName: String,
        appName: String,
        bundleIdentifiers: [String]
    ) {
        self.id = id
        self.displayName = displayName
        self.appName = appName
        self.bundleIdentifiers = bundleIdentifiers
    }

    public static let ghostty = TerminalProfile(
        id: "ghostty", displayName: "Ghostty", appName: "Ghostty",
        bundleIdentifiers: ["com.mitchellh.ghostty", "com.ghostty.ghostty"])
    public static let terminal = TerminalProfile(
        id: "terminal", displayName: "Terminal", appName: "Terminal",
        bundleIdentifiers: ["com.apple.Terminal"])
    public static let iTerm2 = TerminalProfile(
        id: "iterm2", displayName: "iTerm2", appName: "iTerm",
        bundleIdentifiers: ["com.googlecode.iterm2"])
    public static let kitty = TerminalProfile(
        id: "kitty", displayName: "kitty", appName: "kitty",
        bundleIdentifiers: ["net.kovidgoyal.kitty"])
    public static let wezTerm = TerminalProfile(
        id: "wezterm", displayName: "WezTerm", appName: "WezTerm",
        bundleIdentifiers: ["com.github.wez.wezterm"])
    public static let alacritty = TerminalProfile(
        id: "alacritty", displayName: "Alacritty", appName: "Alacritty",
        bundleIdentifiers: ["org.alacritty"])
    public static let warp = TerminalProfile(
        id: "warp", displayName: "Warp", appName: "Warp",
        bundleIdentifiers: ["dev.warp.Warp-Stable", "dev.warp.Warp"])

    public static let supported: [TerminalProfile] = [
        .ghostty, .terminal, .iTerm2, .kitty, .wezTerm, .alacritty, .warp,
    ]
}

public enum TerminalPresentationFailure: Sendable, Equatable {
    case noSupportedTerminalRunning
    case ambiguous(appNames: [String])
    case applicationUnavailable(appName: String)
}

public enum TerminalPresentation: Sendable, Equatable {
    case presented(appName: String)
    case unavailable(TerminalPresentationFailure)
}

/// Brings the terminal containing the attached herdr UI to the foreground.
public protocol TerminalPresenting: Sendable {
    func present() -> TerminalPresentation
}

/// Terminal-neutral macOS foregrounding for Jump.
///
/// Automatic mode only chooses when one running terminal is unambiguous (or is
/// already frontmost). Preferred mode may launch the selected application.
public struct TerminalActivator: TerminalPresenting {
    public enum Selection: Sendable, Equatable {
        case automatic(profiles: [TerminalProfile] = TerminalProfile.supported)
        case preferred(TerminalProfile)
    }

    public let selection: Selection

    public init(selection: Selection = .automatic()) {
        self.selection = selection
    }

    public func present() -> TerminalPresentation {
        #if canImport(AppKit)
        switch selection {
        case .automatic(let profiles):
            let candidates = runningCandidates(for: profiles)
            if let frontmost = NSWorkspace.shared.frontmostApplication,
               let candidate = candidates.first(where: {
                   $0.application.processIdentifier == frontmost.processIdentifier
               }) {
                return activate(candidate.application, profile: candidate.profile)
            }
            guard candidates.count == 1, let candidate = candidates.first else {
                if candidates.isEmpty { return .unavailable(.noSupportedTerminalRunning) }
                return .unavailable(.ambiguous(
                    appNames: Array(Set(candidates.map(\.profile.displayName))).sorted()))
            }
            return activate(candidate.application, profile: candidate.profile)

        case .preferred(let profile):
            if let candidate = runningCandidates(for: [profile]).first {
                return activate(candidate.application, profile: profile)
            }
            return launch(profile)
        }
        #else
        return .unavailable(.noSupportedTerminalRunning)
        #endif
    }

    #if canImport(AppKit)
    private struct RunningCandidate {
        let application: NSRunningApplication
        let profile: TerminalProfile
    }

    private func runningCandidates(for profiles: [TerminalProfile]) -> [RunningCandidate] {
        NSWorkspace.shared.runningApplications.compactMap { application in
            guard let profile = profiles.first(where: {
                $0.bundleIdentifiers.contains(application.bundleIdentifier ?? "")
                    || application.localizedName == $0.appName
            }) else { return nil }
            return RunningCandidate(application: application, profile: profile)
        }
    }

    private func activate(
        _ application: NSRunningApplication,
        profile: TerminalProfile
    ) -> TerminalPresentation {
        application.activate(options: [.activateAllWindows])
        return launch(profile)
    }

    private func launch(_ profile: TerminalProfile) -> TerminalPresentation {
        for bundleIdentifier in profile.bundleIdentifiers where !bundleIdentifier.isEmpty {
            if launchOpen(arguments: ["-b", bundleIdentifier]) {
                return .presented(appName: profile.displayName)
            }
        }
        if !profile.appName.isEmpty, launchOpen(arguments: ["-a", profile.appName]) {
            return .presented(appName: profile.displayName)
        }
        return .unavailable(.applicationUnavailable(appName: profile.displayName))
    }

    private func launchOpen(arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
    #endif
}

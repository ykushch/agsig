import Foundation

/// How this copy of NotchApp got onto the machine. It decides which upgrade
/// instruction the user is given — running `brew upgrade` on a manually
/// installed app does nothing, and telling a Homebrew user to drag a zip into
/// `/Applications` desyncs their Caskroom receipt.
enum InstallOrigin: String, Sendable, Equatable {
    /// Installed with `brew install --cask ykushch/tap/notchagent`.
    case homebrew
    /// Downloaded from GitHub Releases, or built locally with `./bundle.sh`.
    case manual
    /// `swift run NotchApp`, or a `./bundle.sh debug` / dirty-tree build. Never
    /// checks for updates — a developer's build is not behind, it is ahead.
    case development

    static let caskName = "notchagent"

    /// Pure over its inputs so the whole matrix is testable without touching
    /// the real filesystem.
    ///
    /// - Parameters:
    ///   - bundleURL: `Bundle.main.bundleURL`. A path that is not an `.app`
    ///     means the bare SwiftPM executable is running.
    ///   - sourcePath: `NotchAgentSourcePath`, which `bundle.sh` only embeds in
    ///     debug builds.
    ///   - isGitDirty: `NotchAgentGitDirty`, embedded by `bundle.sh`.
    ///   - directoryExists: injected `FileManager` probe.
    static func resolve(
        bundleURL: URL,
        sourcePath: String?,
        isGitDirty: Bool,
        homebrewPrefixes: [String] = defaultHomebrewPrefixes(),
        directoryExists: (String) -> Bool = Self.directoryExists
    ) -> InstallOrigin {
        if bundleURL.pathExtension.lowercased() != "app" { return .development }
        if let sourcePath, !sourcePath.isEmpty { return .development }
        if isGitDirty { return .development }

        let caskroomPaths = homebrewPrefixes.map { prefix in
            (prefix as NSString).appendingPathComponent("Caskroom/\(caskName)")
        }
        if caskroomPaths.contains(where: directoryExists) { return .homebrew }
        return .manual
    }

    /// Reads the provenance keys `bundle.sh` writes into `Info.plist`.
    static func resolve(bundle: Bundle = .main) -> InstallOrigin {
        resolve(
            bundleURL: bundle.bundleURL,
            sourcePath: bundle.object(forInfoDictionaryKey: "NotchAgentSourcePath") as? String,
            isGitDirty: bundle.object(forInfoDictionaryKey: "NotchAgentGitDirty") as? Bool ?? false)
    }

    static func defaultHomebrewPrefixes(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        var prefixes = ["/opt/homebrew", "/usr/local"]
        if let prefix = environment["HOMEBREW_PREFIX"], !prefix.isEmpty,
           !prefixes.contains(prefix) {
            prefixes.insert(prefix, at: 0)
        }
        return prefixes
    }

    private static func directoryExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }
}

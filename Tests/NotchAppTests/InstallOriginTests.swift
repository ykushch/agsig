import Foundation
import Testing
@testable import NotchApp

@Suite("InstallOrigin")
struct InstallOriginTests {
    static let caskroom = "/opt/homebrew/Caskroom/notchagent"

    static func resolve(
        bundlePath: String = "/Applications/NotchApp.app",
        sourcePath: String? = nil,
        isGitDirty: Bool = false,
        existingDirectories: Set<String> = []
    ) -> InstallOrigin {
        InstallOrigin.resolve(
            bundleURL: URL(fileURLWithPath: bundlePath),
            sourcePath: sourcePath,
            isGitDirty: isGitDirty,
            homebrewPrefixes: ["/opt/homebrew", "/usr/local"],
            directoryExists: existingDirectories.contains)
    }

    @Test("A Caskroom receipt means Homebrew owns the upgrade")
    func homebrewInstall() {
        #expect(Self.resolve(existingDirectories: [Self.caskroom]) == .homebrew)
        #expect(Self.resolve(existingDirectories: ["/usr/local/Caskroom/notchagent"]) == .homebrew)
    }

    @Test("An app bundle with no Caskroom receipt was installed by hand")
    func manualInstall() {
        #expect(Self.resolve() == .manual)
        // A different cask's receipt must not be mistaken for ours.
        #expect(Self.resolve(existingDirectories: ["/opt/homebrew/Caskroom/ghostty"]) == .manual)
    }

    @Test("Development builds never check: a dev build is ahead, not behind")
    func developmentBuilds() {
        // `swift run NotchApp` — the executable is not inside an .app.
        #expect(Self.resolve(bundlePath: "/Users/dev/agsig/.build/debug") == .development)
        // `./bundle.sh debug` embeds the source path.
        #expect(Self.resolve(sourcePath: "/Users/dev/agsig") == .development)
        // A dirty tree, however it was bundled.
        #expect(Self.resolve(isGitDirty: true) == .development)
        // Development wins even when a Caskroom receipt happens to exist.
        #expect(Self.resolve(isGitDirty: true, existingDirectories: [Self.caskroom]) == .development)
    }

    @Test("An empty source path is treated as absent")
    func emptySourcePath() {
        #expect(Self.resolve(sourcePath: "") == .manual)
    }

    @Test("HOMEBREW_PREFIX is honored ahead of the standard prefixes")
    func customHomebrewPrefix() {
        let prefixes = InstallOrigin.defaultHomebrewPrefixes(
            environment: ["HOMEBREW_PREFIX": "/custom/brew"])
        #expect(prefixes.first == "/custom/brew")
        #expect(prefixes.contains("/opt/homebrew"))
    }
}

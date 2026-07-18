import Foundation

#if canImport(AppKit)
import AppKit
#endif

/// Raises the Ghostty window on "jump". herdr's `pane.focus` does the
/// within-herdr targeting first; this brings the Ghostty *app* to the front.
///
/// Uses AppleScript (`tell application "Ghostty" to activate`) as the PRIMARY
/// mechanism — it's the one spec 00 validated, and unlike
/// `NSRunningApplication.activate` it reliably raises another app FROM an
/// accessory (`.accessory`) app that itself holds no activation. The native
/// `NSRunningApplication.activate(.activateAllWindows)` is a best-effort
/// pre-nudge; a bare `activate(options: [])` from an accessory app frequently
/// no-ops (why "Jump did nothing"), so we don't rely on it.
public protocol GhosttyActivating: Sendable {
    /// Bring Ghostty to the foreground. Returns false if it couldn't be activated.
    @discardableResult
    func activate() -> Bool
}

public struct GhosttyActivator: GhosttyActivating {
    /// Bundle identifiers Ghostty may ship under.
    public static let bundleIdentifiers = ["com.mitchellh.ghostty", "com.ghostty.ghostty"]
    public let appName: String

    public init(appName: String = "Ghostty") {
        self.appName = appName
    }

    @discardableResult
    public func activate() -> Bool {
        #if canImport(AppKit)
        // Best-effort native nudge with the ALL-windows option (bare [] no-ops from
        // an accessory app). Don't trust its return value.
        let running = NSWorkspace.shared.runningApplications
        if let app = running.first(where: { app in
            Self.bundleIdentifiers.contains(app.bundleIdentifier ?? "")
                || app.localizedName == appName
        }) {
            app.activate(options: [.activateAllWindows])
        }
        #endif
        // Primary raise: `open -a`. Unlike `tell application … to activate`, it
        // needs NO Automation (TCC) permission and reliably brings the app
        // frontmost — including from an accessory app. This is the fix for
        // "Jump did nothing": the old AppleScript activate silently fails without
        // the "NotchApp wants to control Ghostty" grant, and `activate(options:[])`
        // no-ops from an accessory app.
        if launch(args: ["-a", appName]) { return true }
        // Last resort: AppleScript (may require Automation permission).
        return activateViaAppleScript()
    }

    /// Run `/usr/bin/open` with args. Returns true on exit code 0.
    private func launch(args: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = args
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Fallback: `tell application "Ghostty" to activate` (needs Automation perm).
    @discardableResult
    func activateViaAppleScript() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application \"\(appName)\" to activate"]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

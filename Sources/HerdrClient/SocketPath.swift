import Foundation

/// Resolves the herdr Unix-socket path per the documented order:
/// explicit arg → `HERDR_SOCKET_PATH` → `HERDR_SESSION` → default.
public enum SocketPath {
    public static let defaultPath = NSString(string: "~/.config/herdr/herdr.sock")
        .expandingTildeInPath

    /// - Parameters:
    ///   - explicit: a `--session <name>`-style explicit socket *path* (already resolved by a caller), if any.
    ///   - environment: the environment to read (`HERDR_SOCKET_PATH`, `HERDR_SESSION`). Injectable for tests.
    public static func resolve(
        explicit: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let explicit, !explicit.isEmpty {
            return NSString(string: explicit).expandingTildeInPath
        }
        if let fromEnv = environment["HERDR_SOCKET_PATH"], !fromEnv.isEmpty {
            return NSString(string: fromEnv).expandingTildeInPath
        }
        if let session = environment["HERDR_SESSION"], !session.isEmpty {
            return NSString(string: "~/.config/herdr/sessions/\(session)/herdr.sock")
                .expandingTildeInPath
        }
        return defaultPath
    }

    /// Resolve a socket path for a named session (used by the multi-session switcher, spec 10c).
    public static func forSession(_ name: String) -> String {
        NSString(string: "~/.config/herdr/sessions/\(name)/herdr.sock").expandingTildeInPath
    }
}

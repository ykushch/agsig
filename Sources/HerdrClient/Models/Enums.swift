import Foundation

/// Rollup-level agent status. `done` exists only at the rollup level
/// (tab/workspace), never as a per-pane authored state — see `PaneAgentState`.
/// Verified against herdr source `AgentStatus` enum.
public enum AgentStatus: String, Codable, Sendable, CaseIterable {
    case idle
    case working
    case blocked
    case done
    case unknown

    /// Decode-tolerant: any unrecognized value maps to `.unknown` rather than
    /// throwing, so a future herdr status can't crash the client.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentStatus(rawValue: raw) ?? .unknown
    }
}

/// Per-pane *authored* state. **No `done`** — a single pane authority never sets
/// done; done is derived at rollup level. Verified against herdr `PaneAgentState`.
public enum PaneAgentState: String, Codable, Sendable, CaseIterable {
    case idle
    case working
    case blocked
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PaneAgentState(rawValue: raw) ?? .unknown
    }
}

/// `pane.read` source selector. Snake_case on the wire.
public enum ReadSource: String, Codable, Sendable {
    case visible
    case recent
    case recentUnwrapped = "recent_unwrapped"
    case detection
}

/// `notification.show` sound options.
public enum NotificationShowSound: String, Codable, Sendable {
    case none
    case done
    case request
}

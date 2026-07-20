import Foundation

/// A pushed event from `events.subscribe`.
///
/// Wire shape (validated live, herdr 0.7.x): `{"event":"<snake_kind>","data":{…}}`.
/// The inner event name uses snake_case (`pane_agent_status_changed`), while the
/// *subscription* type uses dot form (`pane.agent_status_changed`). We keep the
/// raw `data` as a `JSONValue` and expose typed accessors, so an unrecognized
/// event never fails to decode.
public struct EventEnvelope: Sendable {
    public let event: String
    public let data: JSONValue

    public init(event: String, data: JSONValue) {
        self.event = event
        self.data = data
    }

    /// Parse from a raw pushed line's `JSONValue`. Returns nil if it isn't an event envelope.
    public init?(_ value: JSONValue) {
        guard let event = value["event"]?.stringValue else { return nil }
        self.event = event
        self.data = value["data"] ?? .null
    }

    // Typed accessors for the events the state store consumes.

    /// The pane this event concerns. Most events carry `data.pane_id` directly,
    /// but events with a full pane body (`pane_created`, `pane_focused`, …) nest it
    /// at `data.pane.pane_id`. Check both so callers get the id uniformly.
    public var paneID: String? {
        data["pane_id"]?.stringValue ?? data["pane"]?["pane_id"]?.stringValue
    }

    /// For `pane_agent_status_changed`.
    public var agentStatus: AgentStatus? {
        guard let raw = data["agent_status"]?.stringValue else { return nil }
        return AgentStatus(rawValue: raw) ?? .unknown
    }

    /// For events that carry a full `PaneInfo` (`pane_created`, `pane_focused`, etc.).
    public var pane: PaneInfo? {
        guard let paneValue = data["pane"], !paneValue.isNull else { return nil }
        return try? paneValue.decode(PaneInfo.self)
    }
}

/// Typed decode of a `pane.agent_status_changed` event's data.
public struct PaneAgentStatusChangedEvent: Codable, Sendable, Equatable {
    public let paneID: String
    public let workspaceID: String?
    public let agentStatus: AgentStatus
    public let agent: String?
    public let displayAgent: String?
    public let customStatus: String?

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case workspaceID = "workspace_id"
        case agentStatus = "agent_status"
        case agent
        case displayAgent = "display_agent"
        case customStatus = "custom_status"
    }
}

/// The `pane.read` result (nested under `result.read`).
public struct PaneReadResult: Codable, Sendable, Equatable {
    public let text: String
    public let source: String?
    public let format: String?
    public let paneID: String?

    enum CodingKeys: String, CodingKey {
        case text
        case source
        case format
        case paneID = "pane_id"
    }
}

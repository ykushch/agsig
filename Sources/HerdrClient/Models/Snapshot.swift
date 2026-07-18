import Foundation

/// Scroll position of a pane's viewport.
public struct PaneScrollInfo: Codable, Sendable, Equatable {
    public let offsetFromBottom: Int
    public let maxOffsetFromBottom: Int
    public let viewportRows: Int

    enum CodingKeys: String, CodingKey {
        case offsetFromBottom = "offset_from_bottom"
        case maxOffsetFromBottom = "max_offset_from_bottom"
        case viewportRows = "viewport_rows"
    }
}

/// A pane record from `session.snapshot` / `pane.list` / `pane.get`.
///
/// Required fields (per schema): pane_id, terminal_id, workspace_id, tab_id,
/// focused, agent_status, revision. Everything else is optional.
public struct PaneInfo: Codable, Sendable, Identifiable, Equatable {
    public let paneID: String
    public let terminalID: String
    public let workspaceID: String
    public let tabID: String
    public let focused: Bool
    public let agentStatus: AgentStatus
    public let revision: UInt64

    public let agent: String?
    public let displayAgent: String?
    public let customStatus: String?
    public let label: String?
    public let title: String?
    public let cwd: String?
    public let foregroundCwd: String?
    public let scroll: PaneScrollInfo?

    public var id: String { paneID }

    public init(paneID: String, terminalID: String, workspaceID: String, tabID: String,
                focused: Bool, agentStatus: AgentStatus, revision: UInt64,
                agent: String? = nil, displayAgent: String? = nil, customStatus: String? = nil,
                label: String? = nil, title: String? = nil, cwd: String? = nil,
                foregroundCwd: String? = nil, scroll: PaneScrollInfo? = nil) {
        self.paneID = paneID
        self.terminalID = terminalID
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.focused = focused
        self.agentStatus = agentStatus
        self.revision = revision
        self.agent = agent
        self.displayAgent = displayAgent
        self.customStatus = customStatus
        self.label = label
        self.title = title
        self.cwd = cwd
        self.foregroundCwd = foregroundCwd
        self.scroll = scroll
    }

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case terminalID = "terminal_id"
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case focused
        case agentStatus = "agent_status"
        case revision
        case agent
        case displayAgent = "display_agent"
        case customStatus = "custom_status"
        case label
        case title
        case cwd
        case foregroundCwd = "foreground_cwd"
        case scroll
    }
}

/// A tab record. `agent_status` here is a rollup over the tab's panes.
public struct TabInfo: Codable, Sendable, Identifiable, Equatable {
    public let tabID: String
    public let workspaceID: String
    public let number: Int?
    public let label: String?
    public let focused: Bool?
    public let paneCount: Int?
    public let agentStatus: AgentStatus?

    public var id: String { tabID }

    enum CodingKeys: String, CodingKey {
        case tabID = "tab_id"
        case workspaceID = "workspace_id"
        case number
        case label
        case focused
        case paneCount = "pane_count"
        case agentStatus = "agent_status"
    }
}

/// A workspace record. `agent_status` is a rollup over the workspace's panes.
public struct WorkspaceInfo: Codable, Sendable, Identifiable, Equatable {
    public let workspaceID: String
    public let number: Int?
    public let label: String?
    public let focused: Bool?
    public let paneCount: Int?
    public let tabCount: Int?
    public let activeTabID: String?
    public let agentStatus: AgentStatus?

    public var id: String { workspaceID }

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case number
        case label
        case focused
        case paneCount = "pane_count"
        case tabCount = "tab_count"
        case activeTabID = "active_tab_id"
        case agentStatus = "agent_status"
    }
}

/// An agent record (keyed to a terminal/pane).
public struct AgentInfo: Codable, Sendable, Equatable {
    public let terminalID: String?
    public let paneID: String?
    public let tabID: String?
    public let workspaceID: String?
    public let agent: String?
    public let displayAgent: String?
    public let agentStatus: AgentStatus?
    public let customStatus: String?
    public let focused: Bool?
    public let cwd: String?
    public let foregroundCwd: String?
    public let revision: UInt64?

    enum CodingKeys: String, CodingKey {
        case terminalID = "terminal_id"
        case paneID = "pane_id"
        case tabID = "tab_id"
        case workspaceID = "workspace_id"
        case agent
        case displayAgent = "display_agent"
        case agentStatus = "agent_status"
        case customStatus = "custom_status"
        case focused
        case cwd
        case foregroundCwd = "foreground_cwd"
        case revision
    }
}

/// The `session.snapshot` payload (nested under `result.snapshot`).
public struct Snapshot: Codable, Sendable {
    public let version: String?
    public let `protocol`: Int?
    public let focusedWorkspaceID: String?
    public let focusedTabID: String?
    public let focusedPaneID: String?
    public let workspaces: [WorkspaceInfo]
    public let tabs: [TabInfo]
    public let panes: [PaneInfo]
    public let agents: [AgentInfo]

    enum CodingKeys: String, CodingKey {
        case version
        case `protocol`
        case focusedWorkspaceID = "focused_workspace_id"
        case focusedTabID = "focused_tab_id"
        case focusedPaneID = "focused_pane_id"
        case workspaces
        case tabs
        case panes
        case agents
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        `protocol` = try c.decodeIfPresent(Int.self, forKey: .protocol)
        focusedWorkspaceID = try c.decodeIfPresent(String.self, forKey: .focusedWorkspaceID)
        focusedTabID = try c.decodeIfPresent(String.self, forKey: .focusedTabID)
        focusedPaneID = try c.decodeIfPresent(String.self, forKey: .focusedPaneID)
        // Optional arrays default to empty so a partial snapshot still decodes.
        workspaces = try c.decodeIfPresent([WorkspaceInfo].self, forKey: .workspaces) ?? []
        tabs = try c.decodeIfPresent([TabInfo].self, forKey: .tabs) ?? []
        panes = try c.decodeIfPresent([PaneInfo].self, forKey: .panes) ?? []
        agents = try c.decodeIfPresent([AgentInfo].self, forKey: .agents) ?? []
    }

    /// Panes deduplicated by `pane_id` (the snapshot payload can repeat panes).
    public var uniquePanes: [PaneInfo] {
        var seen = Set<String>()
        var out: [PaneInfo] = []
        for p in panes where !seen.contains(p.paneID) {
            seen.insert(p.paneID)
            out.append(p)
        }
        return out
    }
}

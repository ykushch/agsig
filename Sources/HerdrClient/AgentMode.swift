import Foundation

/// Agent interaction modes that can be identified from a terminal footer.
public enum AgentMode: String, Sendable, Equatable, CaseIterable {
    case manual
    case acceptEdits
    case plan
    case auto
    case dontAsk
    case bypassPermissions
    case `default`

    public var displayName: String {
        switch self {
        case .manual: "Manual"
        case .acceptEdits: "Accept Edits"
        case .plan: "Plan"
        case .auto: "Auto"
        case .dontAsk: "Don't Ask"
        case .bypassPermissions: "Bypass"
        case .default: "Default"
        }
    }
}

/// Reads the visible footer and reports a mode only when an exact, known marker
/// is present. The terminal remains the source of truth; no click-based mode
/// prediction is performed.
public struct ScreenAgentModeProvider: Sendable {
    private let client: any RequestSending

    public init(client: any RequestSending) {
        self.client = client
    }

    public func mode(paneID: String, agentID: String?) async throws -> AgentMode? {
        let params = try PaneReadParams(
            paneID: paneID, source: .visible, lines: 16,
            format: "text", stripAnsi: true).asJSONValue()
        let result = try await client.request("pane.read", params: params)
        guard let value = result["read"],
              let read = try? value.decode(PaneReadResult.self) else {
            throw InteractionProviderError.unreadablePane(paneID: paneID)
        }
        return Self.detectMode(agentID: agentID, terminalText: read.text)
    }

    public static func detectMode(agentID: String?, terminalText: String) -> AgentMode? {
        guard let agentID else { return nil }
        let agent = agentID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard agent == "claude" || agent == "codex" else { return nil }

        let lines = PromptClassifier.stripAnsi(terminalText)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)

        for line in lines.reversed() {
            let value = line.lowercased()
            if value.contains("bypass permissions") { return .bypassPermissions }
            if value.contains("don't ask mode") || value.contains("dont ask mode") {
                return .dontAsk
            }
            if value.contains("auto mode on") { return .auto }
            if value.contains("accept edits on") { return .acceptEdits }
            if value.contains("plan mode on")
                || value.contains("plan mode (shift+tab to cycle)") { return .plan }
            if value.contains("manual mode on") { return .manual }
            if value.contains("default mode") { return .default }
        }
        return nil
    }
}

import Foundation

/// Conservative allowlist for agents whose terminal UI documents Shift-Tab as
/// a mode-cycle command. Unknown agents keep their input untouched.
enum AgentModeCycling {
    private static let supportedAgentIDs: Set<String> = ["claude", "codex"]

    static func isSupported(agentID: String?) -> Bool {
        guard let agentID else { return false }
        let normalized = agentID.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return supportedAgentIDs.contains(normalized)
    }
}

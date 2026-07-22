import Testing
@testable import NotchApp

@Suite("Agent mode cycling support")
struct AgentModeCyclingTests {
    @Test("Known Shift-Tab agents are supported")
    func supportedAgents() {
        #expect(AgentModeCycling.isSupported(agentID: "claude"))
        #expect(AgentModeCycling.isSupported(agentID: "codex"))
        #expect(AgentModeCycling.isSupported(agentID: " CLAUDE "))
    }

    @Test("Unknown or missing agents stay unsupported")
    func unsupportedAgents() {
        #expect(!AgentModeCycling.isSupported(agentID: "opencode"))
        #expect(!AgentModeCycling.isSupported(agentID: ""))
        #expect(!AgentModeCycling.isSupported(agentID: nil))
    }
}

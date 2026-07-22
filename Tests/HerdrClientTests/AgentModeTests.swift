import Testing
@testable import HerdrClient

@Suite("Agent mode footer detection")
struct AgentModeTests {
    @Test("Provider reads a small, plain-text visible footer")
    func providerRead() async throws {
        let client = MockClient()
        client.resultForMethod["pane.read"] = .object([
            "read": .object(["text": .string("⏸ manual mode on")])
        ])

        let mode = try await ScreenAgentModeProvider(client: client).mode(
            paneID: "w1:p4", agentID: "claude")

        #expect(mode == .manual)
        #expect(client.recorded.map(\.method) == ["pane.read"])
        #expect(client.recorded[0].params["pane_id"]?.stringValue == "w1:p4")
        #expect(client.recorded[0].params["source"]?.stringValue == "visible")
        #expect(client.recorded[0].params["lines"]?.intValue == 16)
        #expect(client.recorded[0].params["strip_ansi"]?.boolValue == true)
    }

    @Test("Claude permission modes use the latest visible footer")
    func claudeModes() {
        #expect(ScreenAgentModeProvider.detectMode(
            agentID: "claude",
            terminalText: "old: ⏸ manual mode on\n⏵⏵ auto mode on (shift+tab to cycle)") == .auto)
        #expect(ScreenAgentModeProvider.detectMode(
            agentID: " CLAUDE ", terminalText: "⏵⏵ accept edits on") == .acceptEdits)
        #expect(ScreenAgentModeProvider.detectMode(
            agentID: "claude", terminalText: "⏸ plan mode on") == .plan)
        #expect(ScreenAgentModeProvider.detectMode(
            agentID: "claude", terminalText: "⏸ manual mode on") == .manual)
    }

    @Test("Codex plan footer is detected through ANSI styling")
    func codexPlanMode() {
        let footer = "\u{1B}[38;5;5mPlan mode (shift+tab to cycle)\u{1B}[0m"
        #expect(ScreenAgentModeProvider.detectMode(
            agentID: "codex", terminalText: footer) == .plan)
    }

    @Test("Unknown agents and unrecognized text do not invent a mode")
    func unknownMode() {
        #expect(ScreenAgentModeProvider.detectMode(
            agentID: "opencode", terminalText: "auto mode on") == nil)
        #expect(ScreenAgentModeProvider.detectMode(
            agentID: "claude", terminalText: "working normally") == nil)
    }
}

import Foundation
import Testing
@testable import HerdrClient

private actor FakeOpenCodeClient: OpenCodeNativeRequesting {
    var permissions: [OpenCodePermissionRequest]
    var prompt: String?
    private(set) var replies: [(String, OpenCodePermissionReply)] = []

    init(_ permissions: [OpenCodePermissionRequest], prompt: String? = nil) {
        self.permissions = permissions
        self.prompt = prompt
    }

    func pendingPermissions(
        descriptor: OpenCodePaneDescriptor
    ) async throws -> [OpenCodePermissionRequest] { permissions }

    func lastUserPrompt(descriptor: OpenCodePaneDescriptor) async throws -> String? {
        prompt
    }

    func reply(descriptor: OpenCodePaneDescriptor, requestID: String,
               reply: OpenCodePermissionReply) async throws {
        replies.append((requestID, reply))
        permissions.removeAll { $0.id == requestID }
    }

    func setPermissions(_ value: [OpenCodePermissionRequest]) {
        permissions = value
    }
}

@Suite("OpenCode native provider")
struct OpenCodeNativeProviderTests {
    @Test("herdr tokens admit loopback descriptors and reject remote origins")
    func descriptorSafety() {
        #expect(OpenCodePaneDescriptor(pane: pane(tokens: [
            "opencode_url": "http://127.0.0.1:4096",
            "opencode_session": "ses_123",
            "opencode_model": "anthropic/claude-opus-4-1",
        ]))?.modelID == "anthropic/claude-opus-4-1")
        #expect(OpenCodePaneDescriptor(pane: pane(tokens: [
            "opencode_url": "https://example.com",
            "opencode_session": "ses_123",
        ])) == nil)
        #expect(OpenCodePaneDescriptor(pane: pane(tokens: [
            "opencode_url": "http://user:secret@localhost:4096",
            "opencode_session": "ses_123",
        ])) == nil)
    }

    @Test("native approval revalidates request identity before replying once")
    func nativeApproval() async throws {
        let request = OpenCodePermissionRequest(
            id: "per_123", sessionID: "ses_123", permission: "bash",
            patterns: ["swift test"], always: ["swift *"])
        let client = FakeOpenCodeClient(
            [request], prompt: "Run the test suite before shipping")
        let registry = OpenCodePaneRegistry()
        await registry.replace(panes: [pane(tokens: [
            "opencode_url": "http://localhost:4096",
            "opencode_session": "ses_123",
        ])])
        let provider = OpenCodeNativeInteractionProvider(
            registry: registry, client: client)
        let shown = try await provider.interaction(
            paneID: "w1:p1", agentID: "opencode", paneRevision: 7)

        #expect(shown.interactionID == "per_123")
        #expect(shown.evidence.source == .native)
        #expect(shown.userPromptContext == "Run the test suite before shipping")
        #expect(InteractionDisplayModel(interaction: shown).userContextLine
            == "You: Run the test suite before shipping")
        #expect(shown.choices.map(\.label) == ["Allow Once", "Always Allow", "Deny"])
        #expect(InteractionDisplayModel(interaction: shown).approvalOnceAvailable)
        #expect(InteractionDisplayModel(interaction: shown).approvalPersistChoiceIndex == 1)

        _ = try await OpenCodeNativeInteractionResponder(
            registry: registry, client: client).respond(
                InteractionResponseRequest(
                    paneID: "w1:p1", agentID: "opencode", paneRevision: 7,
                    expectedFingerprint: shown.fingerprint, intent: .approve))
        let replies = await client.replies
        #expect(replies.count == 1)
        #expect(replies[0].0 == "per_123")
        #expect(replies[0].1 == .once)
    }

    @Test("message decoding selects human user text and ignores synthetic context")
    func userMessageText() throws {
        let value: JSONValue = .object([
            "info": .object(["role": "user"]),
            "parts": .array([
                .object(["type": "text", "text": "synthetic", "synthetic": true]),
                .object(["type": "file", "text": "ignored file text"]),
                .object(["type": "text", "text": "  Please ship this.  "]),
                .object(["type": "text", "text": "ignored", "ignored": true]),
            ]),
        ])
        #expect(try value.decode(OpenCodeSessionMessage.self).userText
            == "Please ship this.")
    }

    @Test("installed 1.0 permission schema decodes without losing native identity")
    func legacySchema() throws {
        let value: JSONValue = .object([
            "id": "per_legacy", "sessionID": "ses_123",
            "type": "bash", "title": "Run swift test?",
            "pattern": .array(["swift test"]),
            "metadata": .object(["command": "swift test"]),
            "time": .object(["created": 1]),
            "messageID": "msg_1", "callID": "call_1",
        ])
        let request = try value.decode(OpenCodePermissionRequest.self)
        #expect(request.id == "per_legacy")
        #expect(request.permission == "bash")
        #expect(request.title == "Run swift test?")
        #expect(request.patterns == ["swift test"])
        #expect(request.always == ["swift test"])
    }

    @Test("changed native request ID is stale even when visible text is identical")
    func nativeRequestIdentity() async throws {
        let first = OpenCodePermissionRequest(
            id: "per_1", sessionID: "ses_123", permission: "bash",
            patterns: ["swift test"])
        let second = OpenCodePermissionRequest(
            id: "per_2", sessionID: "ses_123", permission: "bash",
            patterns: ["swift test"])
        let client = FakeOpenCodeClient([first])
        let registry = OpenCodePaneRegistry()
        await registry.replace(panes: [pane(tokens: [
            "opencode_url": "http://localhost:4096",
            "opencode_session": "ses_123",
        ])])
        let provider = OpenCodeNativeInteractionProvider(
            registry: registry, client: client)
        let shown = try await provider.interaction(
            paneID: "w1:p1", agentID: "opencode", paneRevision: 1)
        await client.setPermissions([second])

        await #expect(throws: InteractionResponderError.self) {
            try await OpenCodeNativeInteractionResponder(
                registry: registry, client: client).respond(
                    InteractionResponseRequest(
                        paneID: "w1:p1", agentID: "opencode", paneRevision: 1,
                        expectedFingerprint: shown.fingerprint, intent: .approve))
        }
        #expect(await client.replies.isEmpty)
    }

    private func pane(tokens: [String: String]) -> PaneInfo {
        PaneInfo(
            paneID: "w1:p1", terminalID: "term-1", workspaceID: "w1",
            tabID: "w1:t1", focused: false, agentStatus: .blocked,
            revision: 1, agent: "opencode", tokens: tokens)
    }
}

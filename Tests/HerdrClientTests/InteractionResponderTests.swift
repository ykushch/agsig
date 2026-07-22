import Foundation
import Testing
@testable import HerdrClient

private actor ScriptedInteractionProvider: InteractionProviding {
    private var values: [PendingInteraction]
    private(set) var readCount = 0

    init(_ values: [PendingInteraction]) { self.values = values }

    func interaction(paneID: String, agentID: String?,
                     paneRevision: UInt64?) async throws -> PendingInteraction {
        readCount += 1
        guard !values.isEmpty else {
            throw InteractionProviderError.unreadablePane(paneID: paneID)
        }
        if values.count == 1 { return values[0] }
        return values.removeFirst()
    }
}

private actor PaneReadProviderClient: RequestSending {
    let detection: String
    let visible: String
    private(set) var sources: [String] = []

    init(detection: String, visible: String) {
        self.detection = detection
        self.visible = visible
    }

    func request(_ method: String, params: JSONValue,
                 id: String) async throws -> JSONValue {
        guard method == "pane.read" else { return .null }
        let source = params["source"]?.stringValue ?? ""
        sources.append(source)
        let text = source == "visible" ? visible : detection
        return .object(["read": .object([
            "text": .string(text), "source": .string(source),
            "pane_id": .string("w1:p2"),
        ])])
    }
}

@Suite("M4 interaction provider and responder safety boundary")
struct InteractionResponderTests {
    @Test("screen provider performs fresh dual reads and exact-agent parsing")
    func screenProvider() async throws {
        let detection = Fixtures.string(
            "interactions/codex-plan-single-select-q1-df1ba0216047.fixture/detection.txt")
        let visible = Fixtures.string(
            "interactions/codex-plan-single-select-q1-df1ba0216047.fixture/visible.ansi")
        let client = PaneReadProviderClient(detection: detection, visible: visible)
        let interaction = try await ScreenInteractionProvider(client: client).interaction(
            paneID: "w1:p2", agentID: "codex", paneRevision: 10817)

        #expect(interaction.evidence.providerID == "codex-screen")
        #expect(interaction.title == "Which area would you most like to improve right now?")
        #expect(interaction.choices.count == 4)
        #expect(interaction.presentation.selectedChoiceIndex == 0)
        #expect(await client.sources == ["detection", "visible"])
    }

    @Test("changed stable identity sends zero outbound requests")
    func staleIdentitySendsNothing() async throws {
        let shown = question(title: "Original question", cursor: 0)
        let changed = question(title: "Replacement question", cursor: 0)
        let provider = ScriptedInteractionProvider([changed])
        let client = MockClient()
        let responder = responder(provider: provider, client: client)
        let request = responseRequest(for: shown, intent: .selectChoice(2))

        do {
            _ = try await responder.respond(request)
            Issue.record("Expected stale interaction refusal")
        } catch let InteractionResponderError.staleInteraction(expected, actual) {
            #expect(expected == shown.fingerprint)
            #expect(actual == changed)
        }
        #expect(client.recorded.isEmpty)
        #expect(await provider.readCount == 1)
    }

    @Test("fresh cursor state replans movement after identity validation")
    func freshCursorReplansMovement() async throws {
        let shown = question(title: "Choose", cursor: 0)
        let fresh = question(title: "Choose", cursor: 3)
        #expect(shown.fingerprint == fresh.fingerprint)
        let provider = ScriptedInteractionProvider([fresh])
        let client = MockClient()

        _ = try await responder(provider: provider, client: client).respond(
            responseRequest(for: shown, intent: .selectChoice(0)))

        #expect(client.recorded.map(\.method) == ["pane.send_keys"])
        #expect(client.recorded[0].params["keys"]?.arrayValue?.compactMap(\.stringValue)
            == ["up", "up", "up", "enter"])
    }

    @Test("preview navigation never presses Enter")
    func previewDoesNotSubmit() async throws {
        let shown = question(title: "Compare", cursor: 0, preview: "Short")
        let refreshed = question(title: "Compare", cursor: 2, preview: "Detailed")
        let provider = ScriptedInteractionProvider([shown, refreshed, refreshed])
        let client = MockClient()
        let responder = InteractionResponder(
            provider: provider,
            actions: Actions(client: client, terminal: MockTerminal()),
            settleAttempts: 4, settleDelayNanoseconds: 0,
            sleep: { _ in })

        let result = try await responder.respond(
            responseRequest(for: shown, intent: .previewChoice(2)))

        #expect(client.recorded.count == 1)
        #expect(client.recorded[0].params["keys"]?.arrayValue?.compactMap(\.stringValue)
            == ["down", "down"])
        #expect(result.settledInteraction?.presentation.selectedChoiceIndex == 2)
        #expect(result.settledInteraction?.presentation.selectedChoicePreview == "Detailed")
    }

    @Test("Claude questions use the same revalidating responder path")
    func claudeQuestionIsSafelyAnswerable() async throws {
        let interaction = PromptClassifier().classifyInteraction(
            paneID: "w1:p1", agent: "claude",
            text: Fixtures.string("prompts/ask-question-detection.txt"))
        #expect(interaction.evidence.providerID == "claude-screen")
        #expect(interaction.presentation.mechanism == .arrowNavigate)
        let provider = ScriptedInteractionProvider([interaction])
        let client = MockClient()

        _ = try await responder(provider: provider, client: client).respond(
            InteractionResponseRequest(
                paneID: "w1:p1", agentID: "claude", paneRevision: 1,
                expectedFingerprint: interaction.fingerprint,
                intent: .selectChoice(2)))

        #expect(client.recorded[0].params["keys"]?.arrayValue?.compactMap(\.stringValue)
            == ["down", "down", "enter"])
    }

    @Test("Claude approval choices use the revalidating responder path")
    func claudeApprovalChoiceIsSafelyAnswerable() async throws {
        let text = Fixtures.string(
            "claude-interactions/claude-edit-approval-diff-982df03912ba.fixture/detection.txt")
        let interaction = PromptClassifier().classifyInteraction(
            paneID: "w1:p1", agent: "claude", text: text)
        #expect(interaction.kind == .approval)
        #expect(interaction.presentation.mechanism == .arrowNavigate)
        let provider = ScriptedInteractionProvider([interaction])
        let client = MockClient()

        _ = try await responder(provider: provider, client: client).respond(
            InteractionResponseRequest(
                paneID: "w1:p1", agentID: "claude", paneRevision: 1,
                expectedFingerprint: interaction.fingerprint,
                intent: .selectChoice(1)))

        #expect(await provider.readCount == 1)
        #expect(client.recorded.count == 1)
        #expect(client.recorded[0].params["keys"]?.arrayValue?.compactMap(\.stringValue)
            == ["down", "enter"])
    }

    @Test("responder owns redraw settling and returns the stable next question")
    func settlesNextQuestion() async throws {
        let current = question(title: "Question one", cursor: 0)
        let next = question(title: "Question two", cursor: 1)
        let provider = ScriptedInteractionProvider([current, next, next])
        let client = MockClient()
        let responder = InteractionResponder(
            provider: provider,
            actions: Actions(client: client, terminal: MockTerminal()),
            settleAttempts: 4, settleDelayNanoseconds: 0,
            sleep: { _ in })

        let result = try await responder.respond(
            responseRequest(for: current, intent: .selectChoice(0)))

        #expect(result.validatedInteraction == current)
        #expect(result.settledInteraction == next)
        #expect(await provider.readCount == 3)
        #expect(client.recorded.count == 1)
    }

    @Test("questions and approvals use separate explicit response paths")
    func explicitKindsAndNoAutomaticApproval() async throws {
        let approval = PendingInteraction(
            paneID: "w1:p2", kind: .approval, title: "Run command?",
            choices: [InteractionChoice(label: "Yes")],
            presentation: InteractionPresentation(
                selectedChoiceIndex: 0, mechanism: .ambiguous),
            capabilities: [.approve, .deny, .selectOne], evidence: evidence)
        let client = MockClient()
        let approvalProvider = ScriptedInteractionProvider([approval, approval])
        let approvalResponder = responder(provider: approvalProvider, client: client)

        #expect(client.recorded.isEmpty)
        await #expect(throws: InteractionPlanningError.ambiguousMechanism) {
            try await approvalResponder.respond(
                responseRequest(for: approval, intent: .approve))
        }
        #expect(client.recorded.isEmpty)

        _ = try await approvalResponder.respond(
            responseRequest(for: approval, intent: .deny))
        #expect(client.recorded.count == 1)
        #expect(client.recorded[0].params["keys"]?.arrayValue?.compactMap(\.stringValue)
            == ["esc"])

        let question = question(title: "Question", cursor: 0)
        let questionClient = MockClient()
        await #expect(throws: InteractionResponderError.self) {
            try await responder(
                provider: ScriptedInteractionProvider([question]),
                client: questionClient).respond(
                    responseRequest(for: question, intent: .deny))
        }
        #expect(questionClient.recorded.isEmpty)
    }

    private func responder(provider: any InteractionProviding,
                           client: MockClient) -> InteractionResponder {
        InteractionResponder(
            provider: provider,
            actions: Actions(client: client, terminal: MockTerminal()),
            settleAttempts: 0, settleDelayNanoseconds: 0,
            sleep: { _ in })
    }

    private func responseRequest(for interaction: PendingInteraction,
                                 intent: InteractionResponseIntent)
        -> InteractionResponseRequest {
        InteractionResponseRequest(
            paneID: interaction.paneID, agentID: "codex", paneRevision: 1,
            expectedFingerprint: interaction.fingerprint, intent: intent)
    }

    private var evidence: InteractionEvidence {
        InteractionEvidence(
            source: .screen, providerID: "test", agentID: "codex",
            paneRevision: 1, confidence: .exact)
    }

    private func question(title: String, cursor: Int, preview: String? = nil)
        -> PendingInteraction {
        PendingInteraction(
            paneID: "w1:p2", kind: .question, title: title,
            choices: (1...4).map { InteractionChoice(label: "Option \($0)") },
            presentation: InteractionPresentation(
                selectedChoiceIndex: cursor, mechanism: .arrowNavigate,
                selectedChoicePreview: preview),
            capabilities: [.selectOne, .deny], evidence: evidence)
    }
}

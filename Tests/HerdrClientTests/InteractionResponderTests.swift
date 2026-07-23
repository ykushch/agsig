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

    @Test("captured Claude checkboxes replan toggles from each fresh cursor")
    func claudeMultiSelectUsesFreshCursor() async throws {
        let directory = Fixtures.url(
            "claude-interactions/claude-multiselect-checkbox-question-26732bf99be4.fixture")
        let shown = try InteractionFixtureInspector().inspect(directory: directory)
        let firstCursorMoved = multiSelectState(shown, cursor: 1, checked: [])
        let firstChecked = multiSelectState(shown, cursor: 1, checked: [1])
        let secondCursorMoved = multiSelectState(shown, cursor: 3, checked: [1])
        let secondChecked = multiSelectState(shown, cursor: 3, checked: [1, 3])
        let uncheckCursorMoved = multiSelectState(shown, cursor: 1, checked: [1, 3])
        let firstUnchecked = multiSelectState(shown, cursor: 1, checked: [3])

        let firstClient = MockClient()
        let firstResult = try await settlingResponder(
            provider: ScriptedInteractionProvider(
                [shown, firstCursorMoved, firstCursorMoved,
                 firstChecked, firstChecked]),
            client: firstClient).respond(
                responseRequest(for: shown, agentID: "claude",
                                intent: .setChoice(1, checked: true)))
        #expect(keysSent(by: firstClient) == [["down"], ["enter"]])
        #expect(firstResult.settledInteraction?.presentation.checkedChoiceIndexes == [1])

        let secondClient = MockClient()
        let secondResult = try await settlingResponder(
            provider: ScriptedInteractionProvider(
                [firstChecked, secondCursorMoved, secondCursorMoved,
                 secondChecked, secondChecked]),
            client: secondClient).respond(
                responseRequest(for: firstChecked, agentID: "claude",
                                intent: .setChoice(3, checked: true)))
        #expect(keysSent(by: secondClient) == [["down", "down"], ["enter"]])
        #expect(secondResult.settledInteraction?.presentation.checkedChoiceIndexes == [1, 3])

        let uncheckClient = MockClient()
        let uncheckResult = try await settlingResponder(
            provider: ScriptedInteractionProvider(
                [secondChecked, uncheckCursorMoved, uncheckCursorMoved,
                 firstUnchecked, firstUnchecked]),
            client: uncheckClient).respond(
                responseRequest(for: secondChecked, agentID: "claude",
                                intent: .setChoice(1, checked: false)))
        #expect(keysSent(by: uncheckClient) == [["up", "up"], ["enter"]])
        #expect(uncheckResult.settledInteraction?.presentation.checkedChoiceIndexes == [3])
    }

    @Test("Claude checkbox activation is withheld if its cursor does not settle")
    func claudeMultiSelectDoesNotActivateStaleCursor() async throws {
        let directory = Fixtures.url(
            "claude-interactions/claude-multiselect-checkbox-question-26732bf99be4.fixture")
        let shown = try InteractionFixtureInspector().inspect(directory: directory)
        let provider = ScriptedInteractionProvider(
            [shown, shown, shown, shown, shown])
        let client = MockClient()

        await #expect(throws: InteractionResponderError.choiceCursorDidNotSettle(
            targetIndex: 2)) {
            try await settlingResponder(provider: provider, client: client).respond(
                responseRequest(for: shown, agentID: "claude",
                                intent: .setChoice(2, checked: true)))
        }
        #expect(keysSent(by: client) == [["down", "down"]])
    }

    @Test("Claude multi-select submit waits for its explicit confirmation")
    func claudeMultiSelectSubmit() async throws {
        let directory = Fixtures.url(
            "claude-interactions/claude-multiselect-checkbox-question-26732bf99be4.fixture")
        let captured = try InteractionFixtureInspector().inspect(directory: directory)
        let shown = multiSelectWizardState(captured, activeStep: 0)
        let confirmation = PromptClassifier().classifyInteraction(
            paneID: shown.paneID,
            agent: "claude",
            text: Fixtures.string("prompts/live-review-submit-detection.txt"),
            currentTabLabel: "Submit")
        #expect(confirmation.kind == .reviewSubmit)
        let provider = ScriptedInteractionProvider(
            [shown, confirmation, confirmation, confirmation, confirmation])
        let client = MockClient()

        _ = try await settlingResponder(provider: provider, client: client).respond(
            responseRequest(for: shown, agentID: "claude", intent: .submit))

        #expect(keysSent(by: client) == [["right"], ["enter"]])
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

    private func settlingResponder(
        provider: any InteractionProviding,
        client: MockClient
    ) -> InteractionResponder {
        InteractionResponder(
            provider: provider,
            actions: Actions(client: client, terminal: MockTerminal()),
            settleAttempts: 4,
            settleDelayNanoseconds: 0,
            sleep: { _ in })
    }

    private func responseRequest(for interaction: PendingInteraction,
                                 intent: InteractionResponseIntent)
        -> InteractionResponseRequest {
        responseRequest(for: interaction, agentID: "codex", intent: intent)
    }

    private func responseRequest(
        for interaction: PendingInteraction,
        agentID: String,
        intent: InteractionResponseIntent
    ) -> InteractionResponseRequest {
        InteractionResponseRequest(
            paneID: interaction.paneID, agentID: agentID, paneRevision: 1,
            expectedFingerprint: interaction.fingerprint, intent: intent)
    }

    private func keysSent(by client: MockClient) -> [[String]] {
        client.recorded.compactMap { request in
            request.params["keys"]?.arrayValue?.compactMap(\.stringValue)
        }
    }

    private func multiSelectState(
        _ interaction: PendingInteraction,
        cursor: Int,
        checked: [Int]
    ) -> PendingInteraction {
        PendingInteraction(
            paneID: interaction.paneID,
            interactionID: interaction.interactionID,
            kind: interaction.kind,
            title: interaction.title,
            body: interaction.body,
            progress: interaction.progress,
            choices: interaction.choices,
            steps: interaction.steps,
            presentation: InteractionPresentation(
                selectedChoiceIndex: cursor,
                checkedChoiceIndexes: checked,
                activeStepIndex: interaction.presentation.activeStepIndex,
                mechanism: interaction.presentation.mechanism,
                selectedChoicePreview: interaction.presentation.selectedChoicePreview),
            capabilities: interaction.capabilities,
            evidence: interaction.evidence,
            contentEvidence: interaction.contentEvidence,
            userPromptContext: interaction.userPromptContext,
            safetyState: interaction.safetyState)
    }

    private func multiSelectWizardState(
        _ interaction: PendingInteraction,
        activeStep: Int
    ) -> PendingInteraction {
        PendingInteraction(
            paneID: interaction.paneID,
            interactionID: interaction.interactionID,
            kind: interaction.kind,
            title: interaction.title,
            body: interaction.body,
            progress: InteractionProgress(current: 1, total: 1, unanswered: 0),
            choices: interaction.choices,
            steps: [
                InteractionStep(
                    label: "Improvements", isAnswered: true, isSubmit: false),
                InteractionStep(
                    label: "Submit", isAnswered: true, isSubmit: true),
            ],
            presentation: InteractionPresentation(
                selectedChoiceIndex: interaction.presentation.selectedChoiceIndex,
                checkedChoiceIndexes: interaction.presentation.checkedChoiceIndexes,
                activeStepIndex: activeStep,
                mechanism: interaction.presentation.mechanism,
                selectedChoicePreview: interaction.presentation.selectedChoicePreview),
            capabilities: interaction.capabilities.union([.navigateSteps]),
            evidence: interaction.evidence,
            contentEvidence: interaction.contentEvidence,
            userPromptContext: interaction.userPromptContext,
            safetyState: interaction.safetyState)
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

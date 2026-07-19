import Foundation
import Testing
@testable import HerdrClient

private actor ScriptedInteractionReader: InteractionReading {
    private var values: [String: [InteractionRead]]
    private var calls: [String] = []

    init(_ values: [String: [InteractionRead]]) {
        self.values = values
    }

    func read(paneID: String, agentID: String?,
              paneRevision: UInt64?) async throws -> InteractionRead {
        calls.append(paneID)
        guard var paneValues = values[paneID], !paneValues.isEmpty else {
            throw InteractionProviderError.unreadablePane(paneID: paneID)
        }
        let value = paneValues.count == 1 ? paneValues[0] : paneValues.removeFirst()
        values[paneID] = paneValues
        return value
    }

    func count(for paneID: String) -> Int {
        calls.count { $0 == paneID }
    }
}

private struct ImmediateInteractionResponder: InteractionResponding {
    let interactions: [String: PendingInteraction]

    func respond(
        _ request: InteractionResponseRequest,
        onPhase: @escaping @Sendable (InteractionResponsePhase) async -> Void
    ) async throws -> InteractionResponseResult {
        guard let interaction = interactions[request.paneID] else {
            throw InteractionProviderError.unreadablePane(paneID: request.paneID)
        }
        await onPhase(.revalidating)
        await onPhase(.sending)
        await onPhase(.settling)
        return InteractionResponseResult(
            validatedInteraction: interaction, settledInteraction: interaction)
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations { continuation.resume() }
    }
}

private actor GatedInteractionReader: InteractionReading {
    let first: InteractionRead
    let next: InteractionRead
    let started: AsyncGate
    let release: AsyncGate
    private var callCount = 0

    init(first: InteractionRead, next: InteractionRead,
         started: AsyncGate, release: AsyncGate) {
        self.first = first
        self.next = next
        self.started = started
        self.release = release
    }

    func read(paneID: String, agentID: String?,
              paneRevision: UInt64?) async throws -> InteractionRead {
        callCount += 1
        if callCount == 1 {
            await started.open()
            await release.wait()
            return first
        }
        return next
    }
}

private struct GatedInteractionResponder: InteractionResponding {
    let interaction: PendingInteraction
    let gate: AsyncGate

    func respond(
        _ request: InteractionResponseRequest,
        onPhase: @escaping @Sendable (InteractionResponsePhase) async -> Void
    ) async throws -> InteractionResponseResult {
        await onPhase(.revalidating)
        await onPhase(.sending)
        await onPhase(.settling)
        await gate.wait()
        return InteractionResponseResult(
            validatedInteraction: interaction, settledInteraction: interaction)
    }
}

@Suite("M5 pane interaction coordinator", .serialized)
@MainActor
struct InteractionCoordinatorTests {
    @Test("hydrates every blocked pane and keeps deterministic attention order")
    func hydrationAndAttentionOrder() async {
        let p1 = read(paneID: "w1:p1", title: "Claude question")
        let p2 = read(paneID: "w1:p2", title: "Codex question")
        let p3 = read(paneID: "w1:p3", title: "New question")
        let reader = ScriptedInteractionReader([
            "w1:p1": [p1], "w1:p2": [p2], "w1:p3": [p3],
        ])
        let coordinator = makeCoordinator(
            reader: reader, interactions: [p1.interaction, p2.interaction, p3.interaction])

        let hydrated = await coordinator.reconcile(
            panes: [pane("w1:p1", revision: 1), pane("w1:p2", revision: 1)],
            newlyBlockedPaneIDs: [])

        #expect(hydrated.refreshedPaneIDs == ["w1:p1", "w1:p2"])
        #expect(coordinator.states.count == 2)
        #expect(coordinator.attentionOrder == ["w1:p2", "w1:p1"])
        #expect(coordinator.setDraftText("Claude draft", paneID: "w1:p1"))
        #expect(coordinator.setDraftText("Codex draft", paneID: "w1:p2"))

        await coordinator.select(paneID: "w1:p1")
        #expect(coordinator.attentionOrder == ["w1:p1", "w1:p2"])
        #expect(coordinator.draftText(for: "w1:p1") == "Claude draft")
        #expect(coordinator.draftText(for: "w1:p2") == "Codex draft")

        _ = await coordinator.reconcile(
            panes: [
                pane("w1:p1", revision: 1), pane("w1:p2", revision: 1),
                pane("w1:p3", revision: 1),
            ], newlyBlockedPaneIDs: ["w1:p3"])
        #expect(coordinator.attentionOrder == ["w1:p1", "w1:p3", "w1:p2"])
    }

    @Test("explicit selection always re-reads the blocked pane")
    func selectionAlwaysRereads() async {
        let value = read(paneID: "w1:p1", title: "Question")
        let reader = ScriptedInteractionReader(["w1:p1": [value]])
        let coordinator = makeCoordinator(reader: reader, interactions: [value.interaction])
        _ = await coordinator.reconcile(
            panes: [pane("w1:p1", revision: 1)], newlyBlockedPaneIDs: [])
        #expect(await reader.count(for: "w1:p1") == 1)

        await coordinator.select(paneID: "w1:p1")

        #expect(await reader.count(for: "w1:p1") == 2)
        #expect(coordinator.state(for: "w1:p1")?.lastRefreshReason == .explicitSelection)
    }

    @Test("revision changes refresh non-selected panes while selected pane stays current")
    func revisionRefreshesNonSelectedPane() async {
        let p1 = read(paneID: "w1:p1", title: "Selected")
        let p2a = read(paneID: "w1:p2", title: "Question one")
        let p2b = read(paneID: "w1:p2", title: "Question two")
        let reader = ScriptedInteractionReader([
            "w1:p1": [p1], "w1:p2": [p2a, p2b],
        ])
        let coordinator = makeCoordinator(
            reader: reader, interactions: [p1.interaction, p2a.interaction])
        _ = await coordinator.reconcile(
            panes: [pane("w1:p1", revision: 1), pane("w1:p2", revision: 1)],
            newlyBlockedPaneIDs: [])
        await coordinator.select(paneID: "w1:p1")

        let result = await coordinator.reconcile(
            panes: [pane("w1:p1", revision: 1), pane("w1:p2", revision: 2)],
            newlyBlockedPaneIDs: [])

        #expect(result.refreshedPaneIDs == ["w1:p1", "w1:p2"])
        #expect(coordinator.state(for: "w1:p2")?.interaction?.title == "Question two")
        #expect(coordinator.state(for: "w1:p2")?.lastRefreshReason == .revisionChanged)
    }

    @Test("untrusted revisions use the fourth-poll fallback cadence")
    func fallbackCadence() async {
        let value = read(paneID: "w1:p1", title: "Question")
        let reader = ScriptedInteractionReader(["w1:p1": [value]])
        let coordinator = InteractionCoordinator(
            reader: reader,
            responder: ImmediateInteractionResponder(
                interactions: ["w1:p1": value.interaction]),
            fallbackPollInterval: 4, revisionReliable: false)
        let panes = [pane("w1:p1", revision: nil)]

        _ = await coordinator.reconcile(panes: panes, newlyBlockedPaneIDs: [])
        let event = await coordinator.reconcile(
            panes: panes, newlyBlockedPaneIDs: [],
            countsTowardFallbackCadence: false)
        _ = await coordinator.reconcile(panes: panes, newlyBlockedPaneIDs: [])
        _ = await coordinator.reconcile(panes: panes, newlyBlockedPaneIDs: [])
        #expect(event.refreshedPaneIDs.isEmpty)
        #expect(await reader.count(for: "w1:p1") == 1)

        let fourth = await coordinator.reconcile(
            panes: panes, newlyBlockedPaneIDs: [])

        #expect(fourth.refreshedPaneIDs == ["w1:p1"])
        #expect(await reader.count(for: "w1:p1") == 2)
        #expect(coordinator.state(for: "w1:p1")?.lastRefreshReason == .fallbackCadence)
    }

    @Test("resolved and exited panes clean up state without discarding recoverable drafts")
    func cleanupAndDraftRecovery() async {
        let first = read(paneID: "w1:p1", title: "Original")
        let replacement = read(paneID: "w1:p1", title: "Replacement")
        let reader = ScriptedInteractionReader(["w1:p1": [first, replacement]])
        let coordinator = makeCoordinator(
            reader: reader, interactions: [first.interaction])
        _ = await coordinator.reconcile(
            panes: [pane("w1:p1", revision: 1)], newlyBlockedPaneIDs: [])
        await coordinator.select(paneID: "w1:p1")
        #expect(coordinator.setDraftText("keep this", paneID: "w1:p1"))

        let resolved = await coordinator.reconcile(
            panes: [pane("w1:p1", revision: 2, isBlocked: false)],
            newlyBlockedPaneIDs: [], preserveSelectedResolvedPane: true)

        #expect(resolved.removedPaneIDs == ["w1:p1"])
        #expect(coordinator.state(for: "w1:p1") == nil)
        #expect(coordinator.selectedPaneID == "w1:p1")
        #expect(coordinator.archivedDrafts["w1:p1"]?.text == "keep this")
        #expect(coordinator.archivedDrafts["w1:p1"]?.state == .stale)

        _ = await coordinator.reconcile(
            panes: [pane("w1:p1", revision: 3)],
            newlyBlockedPaneIDs: ["w1:p1"])
        #expect(coordinator.state(for: "w1:p1")?.draft.text == "keep this")
        #expect(coordinator.state(for: "w1:p1")?.draft.state == .stale)
        #expect(!coordinator.setDraftText("overwrite", paneID: "w1:p1"))
        #expect(coordinator.confirmDraftReuse(paneID: "w1:p1"))
        #expect(coordinator.setDraftText("reused", paneID: "w1:p1"))

        _ = await coordinator.reconcile(
            panes: [], newlyBlockedPaneIDs: [],
            preserveSelectedResolvedPane: true)
        #expect(coordinator.selectedPaneID == nil)
        #expect(coordinator.state(for: "w1:p1") == nil)
    }

    @Test("one pane settling never suppresses refresh of another pane")
    func responseDoesNotSuppressAnotherPane() async {
        let p1 = read(paneID: "w1:p1", title: "First")
        let p2a = read(paneID: "w1:p2", title: "Second A")
        let p2b = read(paneID: "w1:p2", title: "Second B")
        let gate = AsyncGate()
        let reader = ScriptedInteractionReader([
            "w1:p1": [p1], "w1:p2": [p2a, p2b],
        ])
        let coordinator = InteractionCoordinator(
            reader: reader,
            responder: GatedInteractionResponder(
                interaction: p1.interaction, gate: gate),
            settleDelayNanoseconds: 0, sleep: { _ in })
        _ = await coordinator.reconcile(
            panes: [pane("w1:p1", revision: 1), pane("w1:p2", revision: 1)],
            newlyBlockedPaneIDs: [])

        let response = Task { @MainActor in
            await coordinator.respond(paneID: "w1:p1", intent: .selectChoice(0))
        }
        for _ in 0..<100 where coordinator.state(for: "w1:p1")?.phase != .settling {
            await Task.yield()
        }
        #expect(coordinator.state(for: "w1:p1")?.phase == .settling)

        let refresh = await coordinator.reconcile(
            panes: [pane("w1:p1", revision: 1), pane("w1:p2", revision: 2)],
            newlyBlockedPaneIDs: [])

        #expect(refresh.refreshedPaneIDs == ["w1:p2"])
        #expect(coordinator.state(for: "w1:p2")?.interaction?.title == "Second B")
        #expect(coordinator.state(for: "w1:p1")?.phase == .settling)

        await gate.open()
        #expect(await response.value)
        #expect(coordinator.state(for: "w1:p1")?.phase == .idle)
        #expect(coordinator.state(for: "w1:p2")?.interaction?.title == "Second B")
    }

    @Test("an old asynchronous read cannot overwrite a recreated pane state")
    func staleReadGenerationIsDiscarded() async {
        let old = read(paneID: "w1:p1", title: "Old generation")
        let new = read(paneID: "w1:p1", title: "New generation")
        let started = AsyncGate()
        let release = AsyncGate()
        let reader = GatedInteractionReader(
            first: old, next: new, started: started, release: release)
        let coordinator = InteractionCoordinator(
            reader: reader,
            responder: ImmediateInteractionResponder(
                interactions: ["w1:p1": new.interaction]))

        let firstReconcile = Task { @MainActor in
            await coordinator.reconcile(
                panes: [pane("w1:p1", revision: 1)],
                newlyBlockedPaneIDs: [])
        }
        await started.wait()
        _ = await coordinator.reconcile(
            panes: [pane("w1:p1", revision: 2, isBlocked: false)],
            newlyBlockedPaneIDs: [])
        _ = await coordinator.reconcile(
            panes: [pane("w1:p1", revision: 2)],
            newlyBlockedPaneIDs: ["w1:p1"])

        #expect(coordinator.state(for: "w1:p1")?.interaction?.title == "New generation")
        await release.open()
        _ = await firstReconcile.value

        #expect(coordinator.state(for: "w1:p1")?.interaction?.title == "New generation")
        #expect(coordinator.state(for: "w1:p1")?.lastRevision == 2)
    }

    private func makeCoordinator(
        reader: ScriptedInteractionReader,
        interactions: [PendingInteraction]
    ) -> InteractionCoordinator {
        InteractionCoordinator(
            reader: reader,
            responder: ImmediateInteractionResponder(
                interactions: Dictionary(
                    uniqueKeysWithValues: interactions.map { ($0.paneID, $0) })),
            settleDelayNanoseconds: 0, sleep: { _ in })
    }

    private func pane(_ paneID: String, revision: UInt64?,
                      isBlocked: Bool = true) -> InteractionPaneSnapshot {
        InteractionPaneSnapshot(
            paneID: paneID,
            agentID: paneID == "w1:p1" ? "claude" : "codex",
            revision: revision, isBlocked: isBlocked)
    }

    private func read(paneID: String, title: String) -> InteractionRead {
        let interaction = PendingInteraction(
            paneID: paneID, kind: .question, title: title,
            choices: [InteractionChoice(label: "One"),
                      InteractionChoice(label: "Two")],
            presentation: InteractionPresentation(
                selectedChoiceIndex: 0, mechanism: .arrowNavigate),
            capabilities: [.selectOne, .deny],
            evidence: InteractionEvidence(
                source: .screen, providerID: "test",
                agentID: paneID == "w1:p1" ? "claude" : "codex",
                paneRevision: 1, confidence: .exact))
        return InteractionRead(
            interaction: interaction,
            legacyPrompt: ClassifiedPrompt(
                kind: .question,
                options: [PromptOption(label: "One", keysToSend: ["enter"])],
                denyKeys: ["esc"], promptText: title,
                isMarkdown: false, questionTitle: title,
                answerStyle: .arrowNavigate))
    }
}

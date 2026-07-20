import Foundation
import Testing
@testable import HerdrClient

@Suite("Pending interaction identity")
struct PendingInteractionIdentityTests {
    private func interaction(
        pane: String = "w1:p1",
        title: String = "Choose a target",
        progress: InteractionProgress? = InteractionProgress(current: 1, total: 2, unanswered: 1),
        choices: [InteractionChoice] = [
            InteractionChoice(label: "Production", description: "Deploy publicly"),
            InteractionChoice(label: "Staging", description: "Deploy privately"),
        ],
        presentation: InteractionPresentation = InteractionPresentation(
            selectedChoiceIndex: 0, checkedChoiceIndexes: [], activeStepIndex: 0,
            mechanism: .arrowNavigate),
        revision: Int = 10,
        contentEvidence: InteractionContentEvidence? = nil
    ) -> PendingInteraction {
        PendingInteraction(
            paneID: pane, kind: .question, title: title, body: "Pick one option",
            progress: progress, choices: choices,
            presentation: presentation,
            evidence: InteractionEvidence(source: .screen, providerID: "test",
                                          paneRevision: revision, confidence: .exact),
            contentEvidence: contentEvidence)
    }

    @Test("cursor, checks, ANSI, alignment, and revision do not change identity")
    func volatilePresentationDoesNotChangeFingerprint() {
        let baseline = interaction()
        let redrawn = interaction(
            title: "\u{1b}[1mChoose     a target\u{1b}[0m",
            choices: [
                InteractionChoice(label: " Production ", description: "Deploy    publicly"),
                InteractionChoice(label: "Staging", description: "Deploy privately"),
            ],
            presentation: InteractionPresentation(
                selectedChoiceIndex: 1, checkedChoiceIndexes: [0], activeStepIndex: 1,
                mechanism: .multiSelect),
            revision: 99)

        #expect(redrawn.fingerprint == baseline.fingerprint)
    }

    @Test("title, progress, and option content each change identity")
    func semanticChangesChangeFingerprint() {
        let baseline = interaction().fingerprint
        #expect(interaction(title: "Choose a region").fingerprint != baseline)
        #expect(interaction(progress: InteractionProgress(current: 2, total: 2, unanswered: 0)).fingerprint != baseline)
        #expect(interaction(choices: [InteractionChoice(label: "Local")]).fingerprint != baseline)
        #expect(interaction(choices: [
            InteractionChoice(label: "Production", description: "Deploy after review"),
            InteractionChoice(label: "Staging", description: "Deploy privately"),
        ]).fingerprint != baseline)
        #expect(interaction(contentEvidence: .command(InteractionCommandEvidence(
            environment: "local", reason: "Build it", command: "swift build")))
            .fingerprint != baseline)
        #expect(interaction(choices: [
            InteractionChoice(label: "Production", description: "Deploy publicly",
                              shortcutKeys: ["p"]),
            InteractionChoice(label: "Staging", description: "Deploy privately"),
        ]).fingerprint != baseline)
    }

    @Test("fingerprinting is deterministic")
    func deterministicFingerprint() {
        #expect(interaction().fingerprint == interaction().fingerprint)
        #expect(interaction().fingerprint.rawValue.count == 64)
    }
}

@Suite("Interaction draft lifecycle")
struct InteractionDraftStoreTests {
    private func interaction(title: String) -> PendingInteraction {
        PendingInteraction(
            paneID: "w1:p2", kind: .question, title: title,
            choices: [InteractionChoice(label: "One")],
            presentation: InteractionPresentation(selectedChoiceIndex: 0,
                mechanism: .arrowNavigate),
            evidence: InteractionEvidence(source: .screen, providerID: "test",
                                          confidence: .exact))
    }

    @Test("unchanged interaction keeps its draft attached")
    func unchanged() {
        let prompt = interaction(title: "First")
        var store = InteractionDraftStore()
        store.setText("my note", for: prompt)
        store.observe(prompt)
        #expect(store.draft(for: prompt)?.text == "my note")
        #expect(store.draft(for: prompt)?.state == .attached)
    }

    @Test("changed interaction preserves old text as stale and does not attach it")
    func changed() {
        let first = interaction(title: "First")
        let second = interaction(title: "Second")
        var store = InteractionDraftStore()
        store.setText("my note", for: first)
        store.observe(second)
        #expect(store.draft(for: first)?.state == .stale)
        #expect(store.draft(for: second) == nil)
        let reused = store.confirmReuse(for: first)
        #expect(!reused)
    }

    @Test("disappeared interaction preserves its draft as stale")
    func disappeared() {
        let prompt = interaction(title: "First")
        var store = InteractionDraftStore()
        store.setText("my note", for: prompt)
        store.interactionDisappeared(paneID: prompt.paneID)
        #expect(store.draft(for: prompt)?.state == .stale)
        let reused = store.confirmReuse(for: prompt)
        #expect(!reused)
    }

    @Test("returned interaction requires explicit reconfirmation")
    func returned() {
        let first = interaction(title: "First")
        let second = interaction(title: "Second")
        var store = InteractionDraftStore()
        store.setText("my note", for: first)
        store.observe(second)
        store.observe(first)
        #expect(store.draft(for: first)?.state == .stale)
        let editedWithoutConfirmation = store.setText("replacement", for: first)
        #expect(!editedWithoutConfirmation)
        #expect(store.draft(for: first)?.text == "my note")
        let reused = store.confirmReuse(for: first)
        #expect(reused)
        let editedAfterConfirmation = store.setText("confirmed note", for: first)
        #expect(editedAfterConfirmation)
        #expect(store.draft(for: first)?.state == .attached)
        #expect(store.draft(for: first)?.text == "confirmed note")
    }
}

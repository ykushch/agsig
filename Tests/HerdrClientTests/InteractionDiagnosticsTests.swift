import Foundation
import Testing
@testable import HerdrClient

private actor DiagnosticPaneClient: RequestSending {
    let detection: String
    let visible: String
    private var methods: [String] = []

    init(detection: String, visible: String) {
        self.detection = detection
        self.visible = visible
    }

    func request(_ method: String, params: JSONValue,
                 id: String) async throws -> JSONValue {
        methods.append(method)
        guard method == "pane.read" else {
            Issue.record("Dry runner invoked non-read method \(method)")
            return .null
        }
        let source = params["source"]?.stringValue ?? ""
        return .object(["read": .object([
            "pane_id": .string("w1:p2"),
            "source": .string(source),
            "text": .string(source == "visible" ? visible : detection),
        ])])
    }

    func recordedMethods() -> [String] { methods }
}

private actor DiagnosticScriptedProvider: InteractionProviding {
    let value: PendingInteraction

    init(_ value: PendingInteraction) { self.value = value }

    func interaction(paneID: String, agentID: String?,
                     paneRevision: UInt64?) async throws -> PendingInteraction {
        value
    }
}

@Suite("M7 interaction diagnostics")
struct InteractionDiagnosticsTests {
    @Test("every captured fixture is verified and inspected deterministically")
    func everyFixtureIsInspectable() throws {
        let root = Fixtures.url("interactions")
        let directories = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "fixture" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(directories.count == 12)
        let inspector = InteractionFixtureInspector()
        let diagnostics = InteractionDiagnosticBuilder()

        for directory in directories {
            let first = try inspector.inspect(directory: directory)
            let second = try inspector.inspect(directory: directory)
            #expect(first == second, "non-deterministic inspect: \(directory.lastPathComponent)")
            let firstJSON = diagnostics.jsonValue(for: first)
            let secondJSON = diagnostics.jsonValue(for: second)
            #expect(try firstJSON.serialized() == secondJSON.serialized())
            #expect(firstJSON["schema_version"]?.intValue == 1)
            #expect(firstJSON["provider"]?["kind"]?.stringValue == "screen")
            #expect(firstJSON["provider"]?["id"]?.stringValue
                == "screen-interaction-provider")
            #expect(firstJSON["adapter"]?.stringValue == first.evidence.providerID)
            #expect(firstJSON["fingerprint"]?.stringValue == first.fingerprint.rawValue)
            #expect(firstJSON["choices"]?.arrayValue?.count == first.choices.count)
            #expect(firstJSON["presentation"]?["mechanism"]?.stringValue
                == first.presentation.mechanism.rawValue)
            #expect(firstJSON["evidence"]?["confidence"]?.stringValue
                == first.evidence.confidence.rawValue)
            #expect(firstJSON["evidence"]?["pane_revision"]?.intValue
                == first.evidence.paneRevision)
            #expect(firstJSON["evidence"]?["captured_text"] == nil)
            #expect(firstJSON["proposed_response_plans"]?.arrayValue != nil)
        }
    }

    @Test("diagnostics expose exact operations and explicit refusals")
    func plansAndRefusals() throws {
        let question = try InteractionFixtureInspector().inspect(directory: Fixtures.url(
            "interactions/codex-plan-single-select-q1-df1ba0216047.fixture"))
        let proposals = InteractionDiagnosticBuilder().proposals(for: question)
        let fourth = proposals.first {
            $0.intent == "select_choice" && $0.choiceIndex == 3
        }
        #expect(fourth?.status == "planned")
        #expect(fourth?.plan?.flattenedKeys == ["down", "down", "down", "enter"])

        let approval = try InteractionFixtureInspector().inspect(directory: Fixtures.url(
            "interactions/codex-command-approval-3dd8a319ff17.fixture"))
        let approvalPlans = InteractionDiagnosticBuilder().proposals(for: approval)
        #expect(approvalPlans.first { $0.intent == "approve" }?.refusal
            == "ambiguous_mechanism")
        #expect(approvalPlans.first { $0.intent == "deny" }?.plan?.flattenedKeys
            == ["esc"])
    }

    @Test("dry run re-reads and plans without invoking any send method")
    func dryRunNeverSends() async throws {
        let directory = Fixtures.url(
            "interactions/codex-plan-single-select-q1-df1ba0216047.fixture")
        let detection = try String(
            contentsOf: directory.appendingPathComponent("detection.txt"),
            encoding: .utf8)
        let visible = try String(
            contentsOf: directory.appendingPathComponent("visible.ansi"),
            encoding: .utf8)
        let shown = PromptClassifier().classifyInteraction(
            paneID: "w1:p2", agent: "codex", text: detection,
            visibleANSIText: visible, paneRevision: 10817)
        let client = DiagnosticPaneClient(detection: detection, visible: visible)
        let result = try await InteractionDryRunner(
            provider: ScreenInteractionProvider(client: client)).run(
                InteractionDryRunRequest(
                    paneID: "w1:p2", agentID: "codex", paneRevision: 10817,
                    expectedFingerprint: shown.fingerprint,
                    intent: .selectChoice(3)))

        #expect(result.status == .planned)
        #expect(result.identityMatched)
        #expect(result.plan?.flattenedKeys == ["down", "down", "down", "enter"])
        #expect(await client.recordedMethods() == ["pane.read", "pane.read"])
        #expect(!(await client.recordedMethods()).contains { $0.hasPrefix("pane.send") })
    }

    @Test("dry run reports stale identity and refuses to plan")
    func staleDryRun() async throws {
        let shown = interaction(title: "Original")
        let fresh = interaction(title: "Replacement")
        let result = try await InteractionDryRunner(
            provider: DiagnosticScriptedProvider(fresh)).run(
                InteractionDryRunRequest(
                    paneID: shown.paneID, agentID: "codex", paneRevision: 2,
                    expectedFingerprint: shown.fingerprint,
                    intent: .selectChoice(0)))
        #expect(result.status == .stale)
        #expect(!result.identityMatched)
        #expect(result.plan == nil)
        #expect(result.refusal == "stale_interaction")
    }

    private func interaction(title: String) -> PendingInteraction {
        PendingInteraction(
            paneID: "w1:p2", kind: .question, title: title,
            choices: [InteractionChoice(label: "One")],
            presentation: InteractionPresentation(
                selectedChoiceIndex: 0, mechanism: .arrowNavigate),
            capabilities: [.selectOne],
            evidence: InteractionEvidence(
                source: .screen, providerID: "test", agentID: "codex",
                paneRevision: 2, confidence: .exact))
    }
}

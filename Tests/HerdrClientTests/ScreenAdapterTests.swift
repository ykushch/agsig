import Foundation
import Testing
@testable import HerdrClient

@Suite("Exact-agent screen adapter registry")
struct ScreenAdapterRegistryTests {
    @Test("exact herdr agent IDs dispatch to their intended adapters")
    func exactDispatch() {
        let registry = ScreenAdapterRegistry.standard
        #expect(registry.adapterID(for: "claude") == "claude-screen")
        #expect(registry.adapterID(for: "codex") == "codex-screen")
        #expect(registry.adapterID(for: "Codex") == "generic-screen")
        #expect(registry.adapterID(for: "codex-cli") == "generic-screen")
        #expect(registry.adapterID(for: nil) == "generic-screen")
    }

    @Test("unknown agents never borrow Claude parsing rules")
    func unknownIsConservative() {
        let text = Fixtures.string("prompts/bash-permission-detection.txt")
        let interaction = PromptClassifier().classifyInteraction(
            paneID: "w1:p9", agent: "future-agent", text: text, paneRevision: 42)
        #expect(interaction.kind == .unknown)
        #expect(interaction.choices.isEmpty)
        #expect(interaction.capabilities == [.manualTerminal])
        #expect(interaction.presentation.mechanism == .manual)
        #expect(interaction.evidence.providerID == "generic-screen")
        #expect(interaction.evidence.paneRevision == 42)
    }

    @Test("malformed recognized Codex screens fall back without structured actions")
    func malformedCodexIsConservative() {
        let interaction = PromptClassifier().classifyInteraction(
            paneID: "w1:p2", agent: "codex",
            text: "Question 1/3 (3 unanswered)\nNo options rendered\n"
                + "tab to add notes | enter to submit answer | esc to interrupt")
        #expect(interaction.kind == .unknown)
        #expect(interaction.choices.isEmpty)
        #expect(interaction.capabilities == [.manualTerminal])
        #expect(interaction.evidence.providerID == "generic-screen")
    }

}

@Suite("Codex adapter over captured M0C corpus")
struct CodexScreenAdapterCorpusTests {
    @Test("every captured Codex interaction matches its expected normalized content")
    func corpusNormalization() throws {
        let root = Fixtures.url("interactions")
        let directories = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "fixture" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(directories.count == 12)

        for directory in directories {
            let metadata = try JSONDecoder().decode(
                PaneFixtureMetadata.self,
                from: Data(contentsOf: directory.appendingPathComponent("metadata.json")))
            let text = try String(
                contentsOf: directory.appendingPathComponent("detection.txt"), encoding: .utf8)
            let interaction = PromptClassifier().classifyInteraction(
                paneID: metadata.sourceCapture.paneID,
                agent: metadata.sourceCapture.agent,
                text: text,
                visibleANSIText: try String(
                    contentsOf: directory.appendingPathComponent("visible.ansi"), encoding: .utf8),
                paneRevision: metadata.sourceCapture.paneRevisionBefore)
            let expected = metadata.annotations

            #expect(interaction.kind == expectedKind(expected.interactionKind),
                    "kind mismatch for \(expected.name)")
            #expect(interaction.evidence.agentID == "codex")
            #expect(interaction.evidence.paneRevision
                == Int(metadata.sourceCapture.paneRevisionBefore))
            #expect(interaction.evidence.capturedText == text)

            if expected.interactionKind == "none" {
                #expect(interaction.evidence.providerID == "generic-screen")
                #expect(interaction.choices.isEmpty)
                #expect(interaction.capabilities == [.manualTerminal])
                continue
            }

            #expect(interaction.evidence.providerID == "codex-screen")
            #expect(interaction.evidence.confidence == .exact)
            #expect(interaction.title == expected.title,
                    "title mismatch for \(expected.name)")
            #expect(interaction.choices.map(\.label) == expected.optionLabels,
                    "labels mismatch for \(expected.name)")
            #expect(interaction.choices.map { $0.description ?? "" }
                == expected.optionDescriptions,
                    "descriptions mismatch for \(expected.name)")
            #expect(interaction.presentation.selectedChoiceIndex
                == expected.observedCursorIndex,
                    "cursor mismatch for \(expected.name)")
            #expect(interaction.presentation.checkedChoiceIndexes
                == expected.observedCheckedIndexes)
            #expect(progressLabel(interaction.progress) == expected.progress,
                    "progress mismatch for \(expected.name)")
            #expect(interaction.presentation.mechanism
                == expectedMechanism(expected.responseMechanism),
                    "mechanism mismatch for \(expected.name)")

            if expected.interactionKind == "question_text_entry" {
                #expect(interaction.capabilities.contains(.enterText))
            }
            if expected.interactionKind == "security_approval" {
                #expect(interaction.kind == .approval)
                #expect(interaction.capabilities.contains(.approve))
                #expect(interaction.capabilities.contains(.deny))
            }
        }
    }

    @Test("cursor-only Codex redraws preserve stable identity")
    func cursorRedrawIdentity() throws {
        let names = [
            "codex-plan-single-select-q1-df1ba0216047.fixture",
            "codex-plan-single-select-q1-cursor2-f8374fd89670.fixture",
            "codex-plan-single-select-q1-cursor4-a48b08d11fd1.fixture",
        ]
        let interactions = try names.map { name in
            let directory = Fixtures.url("interactions/\(name)")
            let text = try String(contentsOf: directory.appendingPathComponent("detection.txt"),
                                  encoding: .utf8)
            return PromptClassifier().classifyInteraction(
                paneID: "w1:p2", agent: "codex", text: text)
        }
        #expect(Set(interactions.map(\.fingerprint)).count == 1)
        #expect(interactions.map { $0.presentation.selectedChoiceIndex }
            == [0, 1, 3])
    }

    private func expectedKind(_ value: String) -> InteractionKind {
        switch value {
        case "question", "question_text_entry": .question
        case "review_submit": .reviewSubmit
        case "security_approval": .approval
        default: .unknown
        }
    }

    private func expectedMechanism(_ value: String) -> InteractionMechanism {
        switch value {
        case "arrow_navigate": .arrowNavigate
        case "free_text_notes": .textEntry
        case "numbered_shortcut_or_arrow": .ambiguous
        default: .manual
        }
    }

    private func progressLabel(_ progress: InteractionProgress?) -> String? {
        guard let progress else { return nil }
        if let current = progress.current, let total = progress.total {
            let base = "Question \(current)/\(total)"
            return progress.unanswered.map { "\(base) (\($0) unanswered)" } ?? base
        }
        return progress.unanswered.map { "\($0) unanswered questions" }
    }
}

@Suite("Claude screen adapter regressions")
struct ClaudeScreenAdapterRegressionTests {
    @Test("all labeled Claude fixtures produce their normalized ground truth")
    func labeledFixtures() throws {
        struct Labels: Decodable {
            struct Fixture: Decodable {
                struct Option: Decodable { let label: String }
                let file: String
                let kind: String
                let options: [Option]
            }
            let fixtures: [Fixture]
        }
        let labels = try JSONDecoder().decode(
            Labels.self, from: Fixtures.data("prompts/labels.json"))
        let classifier = PromptClassifier()
        for fixture in labels.fixtures {
            let text = Fixtures.string("prompts/\(fixture.file)")
            let interaction = classifier.classifyInteraction(
                paneID: "fixture", agent: "claude", text: text)
            let expectedKind: InteractionKind = switch fixture.kind {
            case "approval": .approval
            case "question": .question
            default: .unknown
            }
            #expect(interaction.kind == expectedKind)
            #expect(interaction.evidence.providerID
                == (expectedKind == .unknown ? "generic-screen" : "claude-screen"))
            #expect(interaction.evidence.capturedText == text)
            #expect(interaction.choices.map(\.label) == fixture.options.map(\.label))
        }
    }
}

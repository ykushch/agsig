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
        #expect(directories.count == 14)

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
                #expect(interaction.choices.map(\.shortcutKeys) == [["y"], ["p"], ["esc"]])
                if expected.name == "codex-command-approval-explicit-shortcuts" {
                    guard case .command(let command) = interaction.contentEvidence else {
                        Issue.record("missing typed command evidence")
                        continue
                    }
                    #expect(command.environment == "local")
                    #expect(command.reason == "Allow creating the requested empty file once-proof in the workspace?")
                    #expect(command.command == "touch /private/tmp/notchagent-approval-proof.QD2TKh/once-proof")
                }
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

    @Test("approval parsing is scoped to the latest prompt and requires all verified hints")
    func approvalShortcutSafety() {
        let fixture = Fixtures.string(
            "interactions/codex-command-approval-explicit-shortcuts-0e257cdd8f3b.fixture/detection.txt")
        let scrollback = "Question 1/1\n1. Earlier option\n\n" + fixture
        let parsed = PromptClassifier().classifyInteraction(
            paneID: "w1:p2", agent: "codex", text: scrollback)
        #expect(parsed.presentation.mechanism == .explicitShortcut)
        #expect(parsed.choices.map(\.shortcutKeys) == [["y"], ["p"], ["esc"]])

        let changedHint = fixture.replacingOccurrences(of: "(p)", with: "(x)")
        let refused = PromptClassifier().classifyInteraction(
            paneID: "w1:p2", agent: "codex", text: changedHint)
        #expect(refused.presentation.mechanism == .ambiguous)
        #expect(refused.choices.allSatisfy { $0.shortcutKeys.isEmpty })
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
        case "explicit_shortcut": .explicitShortcut
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

    @Test("latest Claude prompt excludes noisy detection scrollback")
    func latestPromptRegion() throws {
        let prompt = Fixtures.string("prompts/generic-permission-detection.txt")
        let noisy = """
        31 status: "..."       # optional
        32 ---
        33 ```

        1. Earlier generated documentation item
        2. Another generated documentation item

        \(prompt)
        """
        let classifier = PromptClassifier()
        let expected = classifier.classifyInteraction(
            paneID: "fixture", agent: "claude", text: prompt)
        let interaction = classifier.classifyInteraction(
            paneID: "fixture", agent: "claude", text: noisy)

        #expect(interaction.kind == .approval)
        #expect(interaction.title == expected.title)
        #expect(interaction.body == expected.body)
        #expect(interaction.choices == expected.choices)
        #expect(interaction.body?.contains("status") == false)
        #expect(interaction.evidence.capturedText == noisy)

        let titleRange = try #require(prompt.range(of: "Do you want to allow"))
        let barePrompt = prompt[titleRange.lowerBound...]
        let afterOutput = """
        Last generated CLAUDE.md line that must not become approval context.
        ────────────────────────────────────────────────────────────
        \(barePrompt)
        """
        let bareInteraction = classifier.classifyInteraction(
            paneID: "fixture", agent: "claude", text: afterOutput)
        #expect(bareInteraction.title == "Do you want to allow this action?")
        #expect(bareInteraction.body == nil)
        #expect(bareInteraction.choices == expected.choices)
    }

    @Test("captured Claude edit approval exposes a typed diff")
    func capturedEditDiff() throws {
        let directory = Fixtures.url(
            "claude-interactions/claude-edit-approval-diff-982df03912ba.fixture")
        let metadata = try PaneFixtureExtractor().verifyFixture(at: directory)
        let text = try String(contentsOf: directory.appendingPathComponent("detection.txt"),
                              encoding: .utf8)
        let interaction = PromptClassifier().classifyInteraction(
            paneID: metadata.sourceCapture.paneID, agent: "claude", text: text,
            paneRevision: metadata.sourceCapture.paneRevisionBefore)

        #expect(interaction.kind == .approval)
        #expect(interaction.title == "Do you want to make this edit to sample.txt?")
        #expect(interaction.presentation.mechanism == .arrowNavigate)
        #expect(InteractionDisplayModel(interaction: interaction).choicesAreActionable)
        #expect(interaction.choices.map(\.label) == metadata.annotations.optionLabels)
        guard case .diff(let diff) = interaction.contentEvidence else {
            Issue.record("missing typed diff evidence")
            return
        }
        #expect(diff.filePath == "sample.txt")
        #expect(diff.additions == 1)
        #expect(diff.removals == 1)
        #expect(diff.lines == [
            InteractionDiffLine(lineNumber: 1, kind: .context, text: "alpha"),
            InteractionDiffLine(lineNumber: 2, kind: .removal, text: "old value"),
            InteractionDiffLine(lineNumber: 2, kind: .addition, text: "new value"),
        ])
    }
}

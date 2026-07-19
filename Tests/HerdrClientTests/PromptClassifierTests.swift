import Foundation
import Testing
@testable import HerdrClient

@Suite("Normalized Claude screen parsing")
struct PromptClassifierTests {
    private let classifier = PromptClassifier()

    @Test("labeled fixtures match normalized kind and option labels")
    func labeledFixtures() throws {
        struct Labels: Decodable {
            struct Fixture: Decodable {
                struct Option: Decodable { let label: String }
                let file: String
                let kind: String
                let options: [Option]
            }
            let agent: String
            let fixtures: [Fixture]
        }
        let labels = try JSONDecoder().decode(
            Labels.self, from: Fixtures.data("prompts/labels.json"))
        for fixture in labels.fixtures {
            let text = Fixtures.string("prompts/\(fixture.file)")
            let value = classifier.classifyInteraction(
                paneID: "fixture", agent: labels.agent, text: text,
                paneRevision: 7)
            let kind: InteractionKind = switch fixture.kind {
            case "approval": .approval
            case "question": .question
            default: .unknown
            }
            #expect(value.kind == kind)
            #expect(value.choices.map(\.label) == fixture.options.map(\.label))
            #expect(value.evidence.capturedText == text)
            #expect(value.evidence.paneRevision == 7)
        }
    }

    @Test("approval exposes approve, deny, and numbered choices")
    func approval() {
        let value = parse("prompts/generic-permission-detection.txt")
        #expect(value.kind == .approval)
        #expect(value.capabilities.contains(.approve))
        #expect(value.capabilities.contains(.deny))
        #expect(value.presentation.mechanism == .numberedShortcut)
        #expect(value.choices.count == 3)
    }

    @Test("wizard preserves steps, progress, descriptions, and text-entry choices")
    func wizard() {
        let value = parse("prompts/live-askquestion-multi-detection.txt",
                          currentTabLabel: "Topics")
        #expect(value.kind == .question)
        #expect(value.title == "What is this study-coursera folder for?")
        #expect(value.steps.map(\.label) == ["Purpose", "Topics", "My role", "Submit"])
        #expect(value.presentation.activeStepIndex == 1)
        #expect(value.progress?.total == 3)
        #expect(value.progress?.unanswered == 2)
        #expect(value.choices[0].description?.contains("Coursera") == true)
        #expect(value.choices.filter { $0.kind == .textEntry }.count == 2)
        #expect(value.capabilities.contains(.navigateSteps))
        #expect(value.capabilities.contains(.enterText))
    }

    @Test("multiselect preserves checks and plans relative movement")
    func multiselect() throws {
        let value = parse("prompts/live-askquestion-multiselect-detection.txt")
        #expect(value.presentation.mechanism == .multiSelect)
        #expect(value.presentation.checkedChoiceIndexes == [0])
        #expect(value.capabilities.contains(.selectMany))
        let plan = try InteractionResponsePlanner().plan(
            .setChoice(3, checked: true), for: value)
        #expect(plan.flattenedKeys == ["down", "down", "down", "space"])
    }

    @Test("review prompt remains actionable")
    func review() {
        let value = parse("prompts/live-review-submit-detection.txt")
        #expect(value.kind == .question)
        #expect(value.title == "Ready to submit your answers?")
        #expect(value.choices.map(\.label) == ["Submit answers", "Cancel"])
    }

    @Test("unknown or idle content never fabricates actions")
    func conservativeFallback() {
        for text in ["random terminal output", Fixtures.string("prompts/idle-prompt-box-detection.txt")] {
            let value = classifier.classifyInteraction(
                paneID: "fixture", agent: "claude", text: text)
            #expect(value.kind == .unknown)
            #expect(value.choices.isEmpty)
            #expect(value.capabilities == [.manualTerminal])
            #expect(value.presentation.mechanism == .manual)
        }
    }

    @Test("ANSI stripping and highlighted tab extraction are deterministic")
    func ansiUtilities() {
        #expect(PromptClassifier.stripAnsi("a\u{1b}[31mb\u{1b}[0mc") == "abc")
        let line = "□ Purpose  \u{1b}[48;2;20;20;20m□ Topics\u{1b}[0m  ✓ Submit"
        #expect(PromptClassifier.highlightedTabLabel(in: line) == "Topics")
    }

    private func parse(_ path: String, currentTabLabel: String? = nil)
        -> PendingInteraction {
        classifier.classifyInteraction(
            paneID: "fixture", agent: "claude", text: Fixtures.string(path),
            currentTabLabel: currentTabLabel)
    }
}

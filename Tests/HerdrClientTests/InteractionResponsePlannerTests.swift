import Foundation
import Testing
@testable import HerdrClient

@Suite("Interaction response planner")
struct InteractionResponsePlannerTests {
    private let planner = InteractionResponsePlanner()

    @Test("captured Codex key plans match fixture metadata or are explicitly refused as ambiguous")
    func codexCorpusPlans() throws {
        let root = Fixtures.url("interactions")
        let directories = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "fixture" }

        var matched = 0
        var refusedAmbiguous = 0
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
                paneRevision: metadata.sourceCapture.paneRevisionBefore)

            for (name, expectedKeys) in metadata.annotations.expectedResponsePlans {
                guard let intent = intent(named: name) else {
                    Issue.record("No M3 intent mapping for \(metadata.annotations.name).\(name)")
                    continue
                }
                if interaction.presentation.mechanism == .ambiguous, name != "deny" {
                    #expect(throws: InteractionPlanningError.ambiguousMechanism) {
                        try planner.plan(intent, for: interaction)
                    }
                    refusedAmbiguous += 1
                } else {
                    let plan = try planner.plan(intent, for: interaction)
                    #expect(plan.flattenedKeys == expectedKeys,
                            "plan mismatch for \(metadata.annotations.name).\(name)")
                    matched += 1
                }
            }
        }
        #expect(matched == 35)
        #expect(refusedAmbiguous == 3)
    }

    @Test("arrow movement is recomputed from each fresh cursor")
    func freshArrowCursor() throws {
        let first = question(mechanism: .arrowNavigate, cursor: 0)
        let last = question(mechanism: .arrowNavigate, cursor: 3)
        #expect(try planner.plan(.selectChoice(3), for: first).flattenedKeys
            == ["down", "down", "down", "enter"])
        #expect(try planner.plan(.selectChoice(0), for: last).flattenedKeys
            == ["up", "up", "up", "enter"])
    }

    @Test("numbered shortcuts select by number then Enter")
    func numberedShortcut() throws {
        let interaction = question(mechanism: .numberedShortcut, cursor: nil)
        #expect(try planner.plan(.selectChoice(2), for: interaction).flattenedKeys
            == ["3", "enter"])
    }

    @Test("checkbox planner uses fresh cursor and checked state")
    func checkboxToggle() throws {
        let unchecked = question(mechanism: .multiSelect, cursor: 0,
                                 checked: [], selectMany: true)
        #expect(try planner.plan(.setChoice(2, checked: true), for: unchecked).flattenedKeys
            == ["down", "down", "space"])

        let freshlyChecked = question(mechanism: .multiSelect, cursor: 2,
                                      checked: [2], selectMany: true)
        #expect(try planner.plan(.setChoice(2, checked: true), for: freshlyChecked) == .noOp)
        #expect(try planner.plan(.setChoice(2, checked: false), for: freshlyChecked).flattenedKeys
            == ["space"])
    }

    @Test("text entry plans text separately from submission")
    func textEntry() throws {
        let interaction = PendingInteraction(
            paneID: "w1:p2", kind: .question, title: "Notes",
            presentation: InteractionPresentation(mechanism: .textEntry),
            capabilities: [.enterText, .deny], evidence: evidence)
        #expect(try planner.plan(.enterText("details"), for: interaction).operations
            == [.sendText("details")])
        #expect(try planner.plan(.submitText("details"), for: interaction).operations
            == [.sendText("details"), .sendKeys(["enter"])])
        #expect(try planner.plan(.submit, for: interaction).flattenedKeys == ["enter"])
        #expect(try planner.plan(.clearTextEntry, for: interaction).flattenedKeys == ["tab"])
    }

    @Test("ambiguous approvals expose denial but no structured submit")
    func ambiguousApproval() throws {
        let interaction = PendingInteraction(
            paneID: "w1:p2", kind: .approval, title: "Run command?",
            choices: [InteractionChoice(label: "Yes"), InteractionChoice(label: "No")],
            presentation: InteractionPresentation(selectedChoiceIndex: 0,
                                                  mechanism: .ambiguous),
            capabilities: [.approve, .deny, .selectOne], evidence: evidence)
        #expect(try planner.plan(.deny, for: interaction).flattenedKeys == ["esc"])
        #expect(throws: InteractionPlanningError.ambiguousMechanism) {
            try planner.plan(.approve, for: interaction)
        }
        #expect(throws: InteractionPlanningError.ambiguousMechanism) {
            try planner.plan(.selectChoice(0), for: interaction)
        }
        #expect(throws: InteractionPlanningError.ambiguousMechanism) {
            try planner.plan(.submit, for: interaction)
        }
    }

    private var evidence: InteractionEvidence {
        InteractionEvidence(source: .screen, providerID: "test", confidence: .exact)
    }

    private func question(mechanism: InteractionMechanism, cursor: Int?,
                          checked: [Int] = [], selectMany: Bool = false) -> PendingInteraction {
        PendingInteraction(
            paneID: "w1:p2", kind: .question, title: "Choose",
            choices: (1...4).map { InteractionChoice(label: "Option \($0)") },
            presentation: InteractionPresentation(
                selectedChoiceIndex: cursor, checkedChoiceIndexes: checked,
                mechanism: mechanism),
            capabilities: [selectMany ? .selectMany : .selectOne, .deny],
            evidence: evidence)
    }

    private func intent(named name: String) -> InteractionResponseIntent? {
        if name.hasPrefix("option_"), let number = Int(name.dropFirst("option_".count)) {
            return .selectChoice(number - 1)
        }
        return switch name {
        case "add_notes": .beginTextEntry
        case "clear_notes": .clearTextEntry
        case "next_question": .navigateNext
        case "previous_question": .navigatePrevious
        case "submit_all", "proceed", "confirm_selected": .submit
        case "go_back": .selectChoice(1)
        case "approve_once": .approve
        case "approve_persist": .selectChoice(1)
        case "deny": .deny
        case "cancel", "cancel_notes", "interrupt": .cancel
        default: nil
        }
    }
}

@Suite("Normalized interaction display model")
struct InteractionDisplayModelTests {
    @Test("M0C fixtures expose their annotated presentation content")
    func codexCorpusContent() throws {
        let root = Fixtures.url("interactions")
        let directories = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "fixture" }
        for directory in directories {
            let metadata = try JSONDecoder().decode(
                PaneFixtureMetadata.self,
                from: Data(contentsOf: directory.appendingPathComponent("metadata.json")))
            let text = try String(
                contentsOf: directory.appendingPathComponent("detection.txt"), encoding: .utf8)
            let interaction = PromptClassifier().classifyInteraction(
                paneID: metadata.sourceCapture.paneID, agent: "codex", text: text)
            let display = InteractionDisplayModel(interaction: interaction)
            #expect(display.showsManualControls)
            if metadata.annotations.interactionKind == "none" { continue }
            #expect(display.title == metadata.annotations.title)
            #expect(display.progressText == metadata.annotations.progress)
            #expect(display.choices.map(\.label) == metadata.annotations.optionLabels)
            #expect(display.choices.map { $0.description ?? "" }
                == metadata.annotations.optionDescriptions)
            #expect(display.choices.firstIndex(where: \.isSelected)
                == metadata.annotations.observedCursorIndex)
            if metadata.annotations.interactionKind == "question_text_entry" {
                #expect(display.showsTextEntry)
            }
            if metadata.annotations.responseMechanism == "numbered_shortcut_or_arrow" {
                #expect(!display.exposesStructuredSubmit)
                #expect(display.supportMessage?.contains("ambiguous") == true)
            }
        }
    }
}

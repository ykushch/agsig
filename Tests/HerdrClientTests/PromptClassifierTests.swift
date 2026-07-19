import Foundation
import Testing
@testable import HerdrClient

@Suite("Prompt classifier over 40 fixtures")
struct PromptClassifierTests {
    struct Labels: Decodable {
        struct Fixture: Decodable {
            let file: String
            let kind: String
            let options: [Option]

            struct Option: Decodable {
                let label: String
                let keysToSend: [String]?
            }
        }

        let agent: String
        let fixtures: [Fixture]
    }

    func loadLabels() throws -> Labels {
        try JSONDecoder().decode(Labels.self, from: Fixtures.data("prompts/labels.json"))
    }

    @Test("every labeled fixture classifies to the expected kind + option labels + keys")
    func fixtureClassify() throws {
        let labels = try loadLabels()
        let classifier = PromptClassifier()
        for fx in labels.fixtures {
            let text = Fixtures.string("prompts/\(fx.file)")
            let result = classifier.classify(agent: labels.agent, text: text)

            #expect(result.kind.rawValue == expectedKind(fx.kind),
                    "kind mismatch for \(fx.file): got \(result.kind), exp \(fx.kind)")

            let gotLabels = result.options.map(\.label)
            let expLabels = fx.options.map(\.label)
            #expect(gotLabels == expLabels,
                    "options mismatch for \(fx.file): got \(gotLabels), exp \(expLabels)")

            // Verify the keys map to <digit>,enter for each parsed option.
            for (i, opt) in result.options.enumerated() {
                if let expKeys = fx.options[i].keysToSend {
                    #expect(opt.keysToSend == expKeys,
                            "keys mismatch for \(fx.file) option \(i)")
                }
            }
        }
    }

    /// Map labels.json's "kind" vocabulary ("none") to the classifier's (`freeText`).
    func expectedKind(_ labelKind: String) -> String {
        switch labelKind {
        case "none": return "freeText" // idle/negative + raw fallback
        case "approval": return "approval"
        case "question": return "question"
        default: return labelKind
        }
    }

    @Test("bash-permission → approval with Yes / No options mapped to keys")
    func bashPermission() throws {
        let text = Fixtures.string("prompts/bash-permission-detection.txt")
        let r = PromptClassifier().classify(agent: "claude", text: text)
        #expect(r.kind == .approval)
        #expect(r.options.first?.label == "Yes")
        #expect(r.options.first?.keysToSend == ["1", "enter"])
        #expect(r.options.last?.label == "No, and tell Claude what to do differently")
        #expect(r.options.last?.keysToSend == ["2", "enter"])
        #expect(r.denyKeys == ["esc"])
    }

    @Test("ask-question → question kind, three options")
    func askQuestion() throws {
        let text = Fixtures.string("prompts/ask-question-detection.txt")
        let r = PromptClassifier().classify(agent: "claude", text: text)
        #expect(r.kind == .question)
        #expect(r.options.map(\.label) == ["Production", "Staging", "Local only"])
        #expect(r.options[2].keysToSend == ["3", "enter"])
    }

    @Test("idle prompt box → raw fallback, NO keys ever")
    func idleNegative() throws {
        let text = Fixtures.string("prompts/idle-prompt-box-detection.txt")
        let r = PromptClassifier().classify(agent: "claude", text: text)
        #expect(r.kind == .freeText)
        #expect(r.options.isEmpty)
        #expect(r.denyKeys.isEmpty)
    }

    @Test("unknown/garbage shape → raw fallback, never fabricates keys")
    func unknownShape() throws {
        let r = PromptClassifier().classify(
            agent: "claude",
            text: "some totally unrecognized terminal output\n$ ")
        #expect(r.kind == .freeText)
        #expect(r.options.isEmpty)
    }

    @Test("blocking marker but unparseable options → raw fallback (no guessed keys)")
    func blockingButUnparseable() {
        // Has the marker phrase but no numbered menu to parse.
        let r = PromptClassifier().classify(
            agent: "claude",
            text: "Do you want to proceed?\n(no options rendered)")
        #expect(r.kind == .freeText)
        #expect(r.options.isEmpty)
    }

    @Test("unknown agent uses conservative raw fallback even for a Claude-shaped prompt")
    func unknownAgent() throws {
        let text = Fixtures.string("prompts/bash-permission-detection.txt")
        let r = PromptClassifier().classify(agent: "some-new-agent", text: text)
        #expect(r.kind == .freeText)
        #expect(r.options.isEmpty)
        #expect(r.denyKeys.isEmpty)
    }

    @Test("markdown detection flags fenced/heading content")
    func markdownDetection() {
        #expect(PromptClassifier.looksLikeMarkdown("Plan:\n```swift\nlet x = 1\n```"))
        #expect(PromptClassifier.looksLikeMarkdown("Overview\n# Heading\ntext"))
        #expect(!PromptClassifier.looksLikeMarkdown("just a plain line"))
    }

    // MARK: Live AskUserQuestion wizard (captured from a real Claude agent)

    @Test("live multi-question form: extracts question title, steps, descriptions, selection")
    func liveAskQuestionWizard() throws {
        let text = Fixtures.string("prompts/live-askquestion-multi-detection.txt")
        let r = PromptClassifier().classify(agent: "claude", text: text)

        #expect(r.kind == .question)
        // The actual question — previously discarded entirely.
        #expect(r.questionTitle == "What is this study-coursera folder for?")

        // Wizard tab bar: Purpose / Topics / My role / Submit.
        #expect(r.isWizard)
        let stepLabels = r.steps.map(\.label)
        #expect(stepLabels.contains("Purpose"))
        #expect(stepLabels.contains("Topics"))
        #expect(stepLabels.contains("My role"))
        #expect(r.steps.contains { $0.isSubmit })
        // Purpose is answered in the fixture.
        #expect(r.steps.first { $0.label == "Purpose" }?.isAnswered == true)
        #expect(r.steps.first { $0.label == "Topics" }?.isAnswered == false)

        // Options with descriptions + the selected one.
        #expect(r.options.first?.label == "Course notes & summaries")
        #expect(r.options.first?.keysToSend == ["1", "enter"])
        #expect(r.options.first?.description?.contains("comprehensive collection of notes") == true)
        #expect(r.options.first?.isSelected == true) // › ... in the fixture
        #expect(r.options.contains { $0.label == "Exercises & assignments" &&
            $0.description?.contains("Code exercises") == true })
    }

    @Test("multi-select AskUserQuestion: arrow-navigate style, checkboxes, keysToAnswer uses arrows")
    func liveMultiSelectForm() throws {
        let text = Fixtures.string("prompts/live-askquestion-multiselect-detection.txt")
        let r = PromptClassifier().classify(agent: "claude", text: text)

        #expect(r.kind == .question)
        #expect(r.answerStyle == .arrowNavigate) // form ignores number keys
        #expect(r.isMultiSelect)                 // [ ] / [✓] checkboxes
        #expect(r.questionTitle == "How would you like me to help you in this folder?")

        // Checkbox state parsed; label stripped of the [✓].
        #expect(r.options.first?.label == "Organize & take notes")
        #expect(r.options.first?.isChecked == true)
        #expect(r.options.first?.isSelected == true) // › cursor on option 1
        #expect(r.options[1].label == "Tutor or explain")
        #expect(r.options[1].isChecked == false)

        // Choosing option 3 (index 2) navigates down twice then toggles with space —
        // NOT "3",enter (which the form ignores + always picked #1).
        #expect(r.keysToAnswer(optionIndex: 2) == ["down", "down", "space"])
        // Choosing the already-cursored option 1 just toggles in place.
        #expect(r.keysToAnswer(optionIndex: 0) == ["space"])
    }

    @Test("single-select AskUserQuestion uses arrow-navigate + enter, not number keys")
    func liveSingleSelectArrowNav() throws {
        let text = Fixtures.string("prompts/live-askquestion-multi-detection.txt")
        let r = PromptClassifier().classify(agent: "claude", text: text)
        #expect(r.answerStyle == .arrowNavigate)
        #expect(!r.isMultiSelect)
        // Cursor on option 1; choosing option 3 → down,down,enter.
        #expect(r.keysToAnswer(optionIndex: 2) == ["down", "down", "enter"])
    }

    @Test("current wizard tab detected from ANSI highlight; nav keys are left/right")
    func wizardCurrentTabAndNav() throws {
        // Tab bar with the ANSI background-highlight on "Submit" (as captured live).
        let esc = "\u{1b}"
        let bar = "← ☒ Purpose  □ Topics  □ My role  \(esc)[0m\(esc)[38;2;0;0;0m\(esc)[48;2;177;185;249m ✓ Submit \(esc)[0m →"
        let text = """
        \(bar)

        What is this folder for?

        › 1. Course notes
          A knowledge base
          2. Exercises
          Code exercises
        Enter to select · Tab/Arrow keys to navigate · Esc to cancel
        """
        // currentTabLabel is passed SEPARATELY (from an ANSI read), not parsed from text.
        let r = PromptClassifier().classify(agent: "claude", text: text, currentTabLabel: "Submit")
        #expect(r.isWizard)
        #expect(r.steps.first { $0.isCurrent }?.label == "Submit")
        #expect(r.currentStepIndex == 3)
        // Navigate to "Topics" (index 1): from 3 → 1 is two lefts.
        #expect(r.keysToNavigate(toStepIndex: 1) == ["left", "left"])
        #expect(r.keysToNavigate(toStepIndex: 3) == []) // already there
        #expect(r.keysToNavigate(toStepIndex: 0) == ["left", "left", "left"])
    }

    @Test("highlightedTabLabel extracts the current tab from a real ANSI bar")
    func highlightExtraction() throws {
        let esc = "\u{1b}"
        // Highlight on a MIDDLE tab (Topics).
        let mid = "← □ Purpose \(esc)[0m\(esc)[38;2;0;0;0m\(esc)[48;2;177;185;249m □ Topics \(esc)[0m □ My role  ✓ Submit →"
        #expect(PromptClassifier.highlightedTabLabel(in: mid) == "Topics")
        #expect(PromptClassifier.stripAnsi(mid) == "← □ Purpose  □ Topics  □ My role  ✓ Submit →")
        // Highlight on the FIRST tab (Purpose), with a leading SGR run.
        let first = "\(esc)[0m\(esc)[38;2;153;153;153m← \(esc)[0m\(esc)[38;2;0;0;0m\(esc)[48;2;177;185;249m □ Purpose \(esc)[0m □ Topics  □ My role  ✓ Submit →"
        #expect(PromptClassifier.highlightedTabLabel(in: first) == "Purpose")
        // A line with an EARLIER non-tab highlight run (a lone ›) then the tab run:
        // must skip the › and return the real tab label.
        let twoRuns = "\(esc)[48;2;1;2;3m›\(esc)[0m foo \(esc)[48;2;177;185;249m □ Topics \(esc)[0m ✓ Submit"
        #expect(PromptClassifier.highlightedTabLabel(in: twoRuns) == "Topics")
        // Highlight only on a lone cursor (no tab) → nil.
        let cursorOnly = "\(esc)[48;2;1;2;3m›\(esc)[0m 1. Option"
        #expect(PromptClassifier.highlightedTabLabel(in: cursorOnly) == nil)
    }

    @Test("wizard steps parse from clean text; current tab set via param; garbage rejected")
    func wizardStepsRobust() throws {
        // Clean bar + explicit current label.
        let clean = "← ☒ Purpose  □ Topics  □ My role  ✓ Submit →\nWhat?\n› 1. A\n  2. B\nTab/Arrow keys to navigate · Enter to select"
        let r = PromptClassifier().classify(agent: "claude", text: clean, currentTabLabel: "Topics")
        #expect(r.steps.map(\.label) == ["Purpose", "Topics", "My role", "Submit"])
        #expect(r.currentStepIndex == 1)
        #expect(r.keysToNavigate(toStepIndex: 0) == ["left"])

        // Garbage line (the "37 empty boxes" failure): many single-space glyphs +
        // "Submit" must NOT parse into dozens of empty steps.
        let garbage = "□ □ □ □ □ □ □ □ □ □ □ Submit gibberish wrapped content here and more"
        #expect(PromptClassifier.parseWizardSteps(garbage).isEmpty)
    }

    @Test("no current-tab label → current step unknown, navigation is a safe no-op")
    func wizardNoHighlightNav() throws {
        let text = Fixtures.string("prompts/live-askquestion-multi-detection.txt")
        let r = PromptClassifier().classify(agent: "claude", text: text) // no currentTabLabel
        #expect(r.isWizard)
        #expect(r.currentStepIndex == nil) // can't tell without the label
        #expect(r.keysToNavigate(toStepIndex: 0) == []) // never guesses
    }

    @Test("tab bar with trailing CR and inline highlight still parses + detects current")
    func tabBarWithCarriageReturn() throws {
        let esc = "\u{1b}"
        // Exact bytes incl. the trailing \r that herdr's visible read leaves.
        let line = "← ☒ Purpose \(esc)[0m\(esc)[38;2;0;0;0m\(esc)[48;2;177;185;249m □ Topics \(esc)[0m □ My role  ✓ Submit →\r"
        let steps = PromptClassifier.parseWizardSteps(line)
        #expect(steps.map(\.label) == ["Purpose", "Topics", "My role", "Submit"])
        #expect(PromptClassifier.highlightedTabLabel(in: line) == "Topics")
    }

    @Test("stripAnsi removes SGR escapes")
    func stripAnsiWorks() {
        let esc = "\u{1b}"
        #expect(PromptClassifier.stripAnsi("\(esc)[48;2;1;2;3mHi\(esc)[0m") == "Hi")
        #expect(PromptClassifier.stripAnsi("plain") == "plain")
    }

    @Test("permission prompt keeps numbered-shortcut style (number keys work there)")
    func permissionNumbered() throws {
        let text = Fixtures.string("prompts/bash-permission-detection.txt")
        let r = PromptClassifier().classify(agent: "claude", text: text)
        #expect(r.answerStyle == .numberedShortcut)
        #expect(r.keysToAnswer(optionIndex: 1) == ["2", "enter"])
    }

    @Test("review/submit screen is recognized as a question with Submit/Cancel, not raw fallback")
    func reviewSubmitScreen() throws {
        let text = Fixtures.string("prompts/live-review-submit-detection.txt")
        let r = PromptClassifier().classify(agent: "claude", text: text)
        // Must NOT be freeText — the user got trapped when it fell to raw fallback.
        #expect(r.kind == .question)
        #expect(r.options.map(\.label) == ["Submit answers", "Cancel"])
        #expect(r.options.first?.isSelected == true) // › on "Submit answers"
        // Esc still cancels the whole form.
        #expect(r.denyKeys == ["esc"] || r.options.contains { $0.label == "Cancel" })
    }

    @Test("free-text options (Type something / Chat about this) are flagged isTextEntry")
    func textEntryOptions() throws {
        let text = Fixtures.string("prompts/live-askquestion-multiselect-detection.txt")
        let r = PromptClassifier().classify(agent: "claude", text: text)
        // "5. Type something (with › Submit sub-line) and "6. Chat about this"
        let typeOpt = r.options.first { $0.label.lowercased().contains("type something") }
        #expect(typeOpt?.isTextEntry == true)
        let chatOpt = r.options.first { $0.label.lowercased().contains("chat about") }
        #expect(chatOpt?.isTextEntry == true)
        // Normal options are not text-entry.
        #expect(r.options.first { $0.label == "Organize & take notes" }?.isTextEntry == false)
    }

    @Test("an option whose sub-line is just › Submit counts as text entry")
    func submitSublineIsTextEntry() throws {
        let text = """
        ← □ A  ✓ Submit →
        Question here?
        › 1. Real choice
           A description
          2. Type something
             Submit
        Enter to select · Tab/Arrow keys to navigate · Esc to cancel
        """
        let r = PromptClassifier().classify(agent: "claude", text: text)
        #expect(r.options.count == 2)
        #expect(r.options[0].isTextEntry == false)
        #expect(r.options[1].isTextEntry == true) // "Type something" + sub-line "Submit"
    }

    @Test("single-question forms have no wizard steps")
    func singleQuestionNoWizard() throws {
        let text = Fixtures.string("prompts/ask-question-detection.txt")
        let r = PromptClassifier().classify(agent: "claude", text: text)
        #expect(r.kind == .question)
        #expect(!r.isWizard) // no tab bar = not a wizard
        #expect(r.questionTitle == "Which deployment target?")
    }

    @Test("permission prompts have no question title (the prompt IS the question)")
    func approvalNoTitle() throws {
        let text = Fixtures.string("prompts/bash-permission-detection.txt")
        let r = PromptClassifier().classify(agent: "claude", text: text)
        #expect(r.kind == .approval)
        #expect(r.questionTitle == nil)
        #expect(r.steps.isEmpty)
    }
}

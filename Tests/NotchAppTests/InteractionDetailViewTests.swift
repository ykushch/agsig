import AppKit
import HerdrClient
import SwiftUI
import Testing
@testable import NotchApp

@MainActor
@Suite("Interaction detail choices")
struct InteractionDetailViewTests {
    @Test("choice intent resolver preserves option semantics")
    func choiceIntents() {
        let unchecked = choice(index: 1, isChecked: false)
        let checked = choice(index: 2, isChecked: true)
        let option = choice(index: 3)

        #expect(InteractionChoiceIntentResolver.intent(
            for: unchecked, selectedChoicePreview: nil)
            == .setChoice(1, checked: true))
        #expect(InteractionChoiceIntentResolver.intent(
            for: checked, selectedChoicePreview: nil)
            == .setChoice(2, checked: false))
        #expect(InteractionChoiceIntentResolver.intent(
            for: option, selectedChoicePreview: nil)
            == .selectChoice(3))
        #expect(InteractionChoiceIntentResolver.intent(
            for: option, selectedChoicePreview: "Preview")
            == .previewChoice(3))
    }

    @Test(
        "actionable option description remains a pressable button",
        .enabled(if: ProcessInfo.processInfo.environment["NOTCH_UI_HIT_TESTS"] == "1"))
    func actionableDescriptionPress() async {
        var pressCount = 0
        let view = InteractionChoiceButton(
            identifier: "interaction-choice-1",
            isDisabled: false,
            action: { pressCount += 1 }
        ) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Second option")
                Text("Clicking this description must toggle the checkbox.")
                    .textSelection(.disabled)
            }
            .padding(8)
            .frame(width: 360, height: 80, alignment: .leading)
        }
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: 360, height: 80)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()
        await Task.yield()

        let descriptionPoint = NSPoint(x: 180, y: 24)
        for eventType in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: eventType,
                location: descriptionPoint,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: eventType == .leftMouseDown ? 1 : 0)
            else {
                Issue.record("Could not construct \(eventType) event")
                return
            }
            window.sendEvent(event)
        }

        #expect(pressCount == 1)
        window.orderOut(nil)
        window.contentView = nil
        await Task.yield()
        window.close()
    }

    private func choice(index: Int, isChecked: Bool? = nil)
        -> InteractionDisplayChoice {
        InteractionDisplayChoice(
            index: index,
            kind: .option,
            label: "Option \(index + 1)",
            description: "Description",
            isSelected: index == 0,
            isChecked: isChecked)
    }

}

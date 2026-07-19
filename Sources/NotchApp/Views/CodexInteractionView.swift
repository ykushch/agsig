import SwiftUI
import HerdrClient

/// Faithful normalized Codex presentation. Every structured action is routed to
/// M4's fresh-read responder; manual terminal controls remain outside this view.
struct CodexInteractionView: View {
    let interaction: PendingInteraction
    @Binding var manualText: String
    let isResponding: Bool
    let respond: (InteractionResponseIntent) -> Void

    private var display: InteractionDisplayModel {
        InteractionDisplayModel(interaction: interaction)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let progress = display.progressText {
                Text(progress)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.cyan.opacity(0.9))
                    .monospacedDigit()
            }
            if let title = display.title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let body = display.body, !body.isEmpty {
                ScrollView {
                    Text(body)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 90)
            }
            if !display.choices.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(display.choices, id: \.index) { choice in
                        choiceRow(choice)
                    }
                }
            }
            if display.showsBeginTextEntry {
                Button("Add notes") { respond(.beginTextEntry) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.cyan)
                    .disabled(isResponding)
            }
            if display.showsTextEntry { manualTextEntry }
            structuredControls
            if let message = display.supportMessage {
                Text(message)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(display.exposesStructuredSubmit
                        ? .white.opacity(0.45) : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func choiceRow(_ choice: InteractionDisplayChoice) -> some View {
        if display.choicesAreActionable {
            Button { respond(choiceIntent(choice)) } label: {
                choiceContent(choice)
            }
            .buttonStyle(.plain)
            .disabled(isResponding)
            .help("Re-read this prompt and select option \(choice.index + 1)")
        } else {
            choiceContent(choice)
        }
    }

    private func choiceContent(_ choice: InteractionDisplayChoice) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: choice.isSelected ? "chevron.right" : "circle")
                .font(.system(size: choice.isSelected ? 10 : 5, weight: .bold))
                .foregroundStyle(choice.isSelected ? .green : .white.opacity(0.3))
                .frame(width: 10, height: 14)
            Text("\(choice.index + 1).")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(choice.isSelected ? .green : .white.opacity(0.65))
                .monospacedDigit()
            if let checked = choice.isChecked {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 11))
                    .foregroundStyle(checked ? .green : .white.opacity(0.4))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(choice.label)
                    .font(.system(size: 11, weight: choice.isSelected ? .semibold : .regular))
                    .foregroundStyle(.white)
                if let description = choice.description {
                    Text(description)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(
            choice.isChecked == true ? Color.green.opacity(0.18)
                : choice.isSelected ? Color.white.opacity(0.14) : Color.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(
            choice.isSelected ? Color.green.opacity(0.6) : .clear, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(choice))
        .accessibilityAddTraits(display.choicesAreActionable ? .isButton : [])
    }

    private var manualTextEntry: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Notes / text")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            HStack(spacing: 6) {
                TextField("type your answer…", text: $manualText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .onSubmit { submitText() }
                    .disabled(isResponding)
                Button("Submit") { submitText() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.cyan)
                    .disabled(manualText.isEmpty || isResponding)
                    .help("Revalidate the prompt, type this text, and submit it")
            }
            Button("Clear notes") { respond(.clearTextEntry) }
                .buttonStyle(.plain)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .disabled(isResponding)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.cyan.opacity(0.09)))
    }

    @ViewBuilder
    private var structuredControls: some View {
        if interaction.capabilities.contains(.navigateSteps) {
            HStack(spacing: 12) {
                Button("← Previous") { respond(.navigatePrevious) }
                Button("Next →") { respond(.navigateNext) }
            }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.cyan)
            .disabled(isResponding)
        }
        if interaction.kind == .approval {
            HStack(spacing: 12) {
                if interaction.presentation.mechanism != .ambiguous {
                    Button("Approve") { respond(.approve) }
                }
                Button("Deny") { respond(.deny) }
            }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.cyan)
            .disabled(isResponding)
        } else if display.showsCancel {
            Button("Cancel") { respond(.cancel) }
                .buttonStyle(.plain)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .disabled(isResponding)
        }
        if isResponding {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Revalidating live prompt…")
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.white.opacity(0.6))
        }
    }

    private func choiceIntent(_ choice: InteractionDisplayChoice)
        -> InteractionResponseIntent {
        if let checked = choice.isChecked {
            return .setChoice(choice.index, checked: !checked)
        }
        return .selectChoice(choice.index)
    }

    private func submitText() {
        let text = manualText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        respond(.submitText(text))
    }

    private func accessibilityLabel(_ choice: InteractionDisplayChoice) -> String {
        var parts = ["Option \(choice.index + 1)", choice.label]
        if choice.isSelected { parts.append("cursor selected") }
        if choice.isChecked == true { parts.append("checked") }
        if choice.isChecked == false { parts.append("unchecked") }
        if let description = choice.description { parts.append(description) }
        return parts.joined(separator: ", ")
    }
}

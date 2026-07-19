import SwiftUI
import HerdrClient

/// Faithful normalized Codex presentation. M3 intentionally has no structured
/// response closure; M4 will add one behind fresh interaction revalidation.
struct CodexInteractionView: View {
    let interaction: PendingInteraction
    @Binding var manualText: String
    let typeTextWithoutSubmit: () -> Void

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
            if display.showsTextEntry { manualTextEntry }
            if let message = display.supportMessage {
                Text(message)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(display.exposesStructuredSubmit
                        ? .white.opacity(0.45) : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func choiceRow(_ choice: InteractionDisplayChoice) -> some View {
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
    }

    private var manualTextEntry: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Manual notes / text")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            HStack(spacing: 6) {
                TextField("type without submitting…", text: $manualText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .onSubmit(typeTextWithoutSubmit)
                Button("Type") { typeTextWithoutSubmit() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.cyan)
                    .disabled(manualText.isEmpty)
                    .help("Type into the pane without pressing Enter")
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.cyan.opacity(0.09)))
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

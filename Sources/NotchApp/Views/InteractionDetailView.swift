import AppKit
import HerdrClient
import SwiftUI

/// Agent-neutral rendering for the normalized interaction contract.
struct InteractionDetailView: View {
    let interaction: PendingInteraction
    @Binding var draftText: String
    let phase: PaneInteractionPhase
    let hotkeySymbols: String
    let respond: (InteractionResponseIntent) -> Void

    private var display: InteractionDisplayModel {
        InteractionDisplayModel(interaction: interaction)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            stepBar
            if let progress = display.progressText {
                Text(progress).font(.caption.weight(.semibold))
                    .foregroundStyle(.cyan).monospacedDigit()
            }
            if let title = display.title {
                Text(title).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
            }
            evidenceCard
            if interaction.contentEvidence == nil,
               let body = display.body, !body.isEmpty {
                Text(body).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7)).textSelection(.enabled)
                    .lineLimit(8).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(display.choices, id: \.index) { choice in
                choiceRow(choice)
            }
            if display.showsBeginTextEntry {
                Button("Add notes") { respond(.beginTextEntry) }
                    .detailActionStyle(disabled: phase.isBusy)
            }
            if display.showsTextEntry {
                textEntry(submit: { InteractionResponseIntent.submitText($0) })
            }
            structuredControls
            if let message = display.supportMessage {
                Text(message).font(.system(size: 9, weight: .medium))
                    .foregroundStyle(display.exposesStructuredSubmit
                        ? .white.opacity(0.45) : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            phaseStatus
        }
        .padding(interaction.kind == .approval ? 10 : 0)
        .background {
            if interaction.kind == .approval {
                RoundedRectangle(cornerRadius: 11)
                    .fill(Color.orange.opacity(0.11))
            }
        }
        .overlay {
            if interaction.kind == .approval {
                RoundedRectangle(cornerRadius: 11)
                    .stroke(Color.orange.opacity(0.38), lineWidth: 1)
            }
        }
    }

    @ViewBuilder private var evidenceCard: some View {
        switch interaction.contentEvidence {
        case .command(let evidence):
            commandCard(evidence)
        case .diff(let evidence):
            diffCard(evidence)
        case nil:
            EmptyView()
        }
    }

    private func commandCard(_ evidence: InteractionCommandEvidence) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Label("Command", systemImage: "terminal")
                    .font(.system(size: 9, weight: .semibold))
                Spacer()
                if let environment = evidence.environment {
                    Text(environment.uppercased())
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(.orange)
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(evidence.command, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain).help("Copy command")
                .accessibilityLabel("Copy command")
            }
            Text(evidence.command)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let reason = evidence.reason {
                Text(reason).font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8).foregroundStyle(.white.opacity(0.75))
        .background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.orange.opacity(0.28)))
    }

    private func diffCard(_ evidence: InteractionDiffEvidence) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Label(evidence.filePath, systemImage: "doc.text")
                    .font(.system(size: 9, weight: .semibold)).lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("+\(evidence.additions)").foregroundStyle(.green)
                Text("−\(evidence.removals)").foregroundStyle(.red)
            }
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .padding(8)
            ForEach(Array(evidence.lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 6) {
                    Text(line.lineNumber.map(String.init) ?? "")
                        .frame(width: 20, alignment: .trailing)
                        .foregroundStyle(.white.opacity(0.32))
                    Text(diffMarker(line.kind)).frame(width: 7)
                        .foregroundStyle(diffForeground(line.kind))
                    Text(line.text).foregroundStyle(.white.opacity(0.86))
                    Spacer(minLength: 0)
                }
                .font(.system(size: 9, design: .monospaced))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(diffBackground(line.kind))
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.35)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.12)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Proposed changes to \(evidence.filePath), \(evidence.additions) additions, \(evidence.removals) removals")
    }

    private func diffMarker(_ kind: InteractionDiffLineKind) -> String {
        switch kind { case .context: " "; case .removal: "−"; case .addition: "+" }
    }

    private func diffForeground(_ kind: InteractionDiffLineKind) -> Color {
        switch kind { case .context: .white.opacity(0.5); case .removal: .red; case .addition: .green }
    }

    private func diffBackground(_ kind: InteractionDiffLineKind) -> Color {
        switch kind { case .context: .clear; case .removal: .red.opacity(0.12); case .addition: .green.opacity(0.12) }
    }

    @ViewBuilder private var stepBar: some View {
        if !interaction.steps.isEmpty {
            HStack(spacing: 5) {
                ForEach(interaction.steps.indices, id: \.self) { index in
                    let step = interaction.steps[index]
                    Button {
                        respond(.navigateToStep(index))
                    } label: {
                        Text(step.isSubmit ? "Submit" : step.label)
                            .font(.system(size: 9, weight: index == interaction.presentation.activeStepIndex ? .bold : .medium))
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(index == interaction.presentation.activeStepIndex
                        ? .cyan : step.isAnswered ? .green : .white.opacity(0.55))
                    .disabled(phase.isBusy || !interaction.capabilities.contains(.navigateSteps))
                    .accessibilityLabel("Step \(index + 1), \(step.label)\(step.isAnswered ? ", answered" : "")")
                }
            }
        }
    }

    @ViewBuilder private func choiceRow(_ choice: InteractionDisplayChoice) -> some View {
        if choice.kind == .textEntry {
            VStack(alignment: .leading, spacing: 5) {
                choiceContent(choice)
                textEntry(submit: { .submitChoiceText(choice.index, $0) })
            }
        } else if display.choicesAreActionable {
            Button { respond(choiceIntent(choice)) } label: { choiceContent(choice) }
                .buttonStyle(.plain).disabled(phase.isBusy)
        } else {
            choiceContent(choice)
        }
    }

    private func choiceContent(_ choice: InteractionDisplayChoice) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text("\(choice.index + 1).").font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(choice.isSelected ? .green : .white.opacity(0.65))
            if let checked = choice.isChecked {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(checked ? .green : .white.opacity(0.4))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(choice.label).font(.system(size: 11, weight: choice.isSelected ? .semibold : .regular))
                    .foregroundStyle(.white)
                if let description = choice.description {
                    Text(description).font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
                }
            }
            Spacer(minLength: 0)
            if choice.index < 9 {
                Text("\(hotkeySymbols)\(choice.index + 1)")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.42))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(.white.opacity(0.08)))
            }
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(
            choice.isChecked == true ? Color.green.opacity(0.18)
                : choice.isSelected ? .white.opacity(0.14) : .white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(
            choice.isSelected ? .green.opacity(0.6) : .clear))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Option \(choice.index + 1), \(choice.label)")
    }

    private func textEntry(
        submit intent: @escaping (String) -> InteractionResponseIntent
    ) -> some View {
        HStack(spacing: 6) {
            TextField("Type your answer…", text: $draftText)
                .textFieldStyle(.roundedBorder).font(.system(size: 11))
                .onSubmit { submitText(intent) }.disabled(phase.isBusy)
            Button("Submit") { submitText(intent) }
                .detailActionStyle(disabled: draftText.isEmpty || phase.isBusy)
        }
    }

    @ViewBuilder private var structuredControls: some View {
        if interaction.capabilities.contains(.navigateSteps) {
            HStack(spacing: 12) {
                Button("← Previous") { respond(.navigatePrevious) }
                Button("Next →") { respond(.navigateNext) }
            }.detailActionStyle(disabled: phase.isBusy)
        }
        if interaction.kind == .approval {
            VStack(alignment: .leading, spacing: 7) {
                Label("Command approval", systemImage: "shield.lefthalf.filled")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.orange)
                HStack(spacing: 7) {
                    if display.approvalOnceAvailable {
                        approvalButton("Allow Once", systemImage: "checkmark",
                                       color: .green) { respond(.approve) }
                    }
                    if let index = display.approvalPersistChoiceIndex {
                        approvalButton(
                            interaction.evidence.source == .native
                                ? "Allow Always" : "Allow Prefix",
                            systemImage: "checkmark.shield",
                                       color: .orange) { respond(.selectChoice(index)) }
                    }
                    if interaction.capabilities.contains(.deny) {
                        approvalButton("Deny", systemImage: "xmark",
                                       color: .red) { respond(.deny) }
                    }
                }
            }
        } else if display.showsCancel {
            Button("Cancel") { respond(.cancel) }
                .detailActionStyle(disabled: phase.isBusy)
        }
    }

    private func approvalButton(
        _ title: String, systemImage: String, color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 7).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(color.opacity(0.15)))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(color.opacity(0.35)))
        }
        .buttonStyle(.plain)
        .disabled(phase.isBusy)
    }

    @ViewBuilder private var phaseStatus: some View {
        if phase != .idle {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(phaseText)
            }.font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.6))
        }
    }

    private var phaseText: String {
        switch phase {
        case .reading: "Reading live prompt…"
        case .responding: "Revalidating and sending…"
        case .settling: "Waiting for terminal redraw…"
        case .idle: ""
        }
    }

    private func choiceIntent(_ choice: InteractionDisplayChoice) -> InteractionResponseIntent {
        choice.isChecked.map { .setChoice(choice.index, checked: !$0) }
            ?? .selectChoice(choice.index)
    }

    private func submitText(_ intent: (String) -> InteractionResponseIntent) {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        respond(intent(text))
    }
}

private extension View {
    func detailActionStyle(disabled: Bool) -> some View {
        buttonStyle(.plain).font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.cyan).disabled(disabled)
    }
}

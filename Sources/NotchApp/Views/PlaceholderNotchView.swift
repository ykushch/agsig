import SwiftUI
import HerdrClient

/// The notch panel's content, bound to the live herdr state (specs 08/09).
struct PlaceholderNotchView: View {
    @Bindable var model: NotchViewModel
    let notchWidth: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            pill
            if model.isExpanded {
                expandedCard.transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: model.isExpanded)
    }

    // MARK: Collapsed pill

    private var pill: some View {
        HStack(spacing: 6) {
            Circle().fill(color(for: model.overallStatus)).frame(width: 8, height: 8)
            Text("\(model.agentCount)")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white).monospacedDigit()
            if model.attentionCount > 0 {
                Text("\(model.attentionCount)▲")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 12).frame(height: 24).frame(minWidth: notchWidth)
        .background(Capsule(style: .continuous).fill(.black.opacity(0.85)))
        .contentShape(Capsule(style: .continuous))
        .onTapGesture { model.toggle() }
        .help("herdr agents — click to expand")
    }

    // MARK: Expanded card

    private var expandedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if model.connection == .unavailable { herdrUnavailable }
            if let pane = model.selectedPaneID,
               let interaction = model.selectedCodexInteraction {
                codexInteractionSection(pane: pane, interaction: interaction)
                Divider().overlay(.white.opacity(0.15))
            } else if let pane = model.selectedPaneID, let prompt = model.selectedPrompt {
                promptSection(pane: pane, prompt: prompt)
                Divider().overlay(.white.opacity(0.15))
            } else if let pane = model.selectedPaneID {
                idleAgentSection(pane: pane)
                Divider().overlay(.white.opacity(0.15))
            } else if model.attentionCount > 0 {
                Text("\(model.attentionCount) agent\(model.attentionCount == 1 ? "" : "s") need input — tap below to answer")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.red)
            }
            agentList
            if let error = model.lastError {
                Text(error).font(.system(size: 10, weight: .medium)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.accessibilityMissing {
                Text("Global hotkeys need Accessibility permission (System Settings › Privacy › Accessibility).")
                    .font(.system(size: 9)).foregroundStyle(.orange.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14).frame(width: 340, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.black.opacity(0.92)))
        .padding(.top, 6)
    }

    private var herdrUnavailable: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("herdr isn't reachable. Is the server running?")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.85))
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.orange.opacity(0.15)))
    }

    private var header: some View {
        HStack {
            Text("Notch Agent").font(.headline).foregroundStyle(.white)
            Spacer()
            Button { model.collapse() } label: {
                Image(systemName: "chevron.up").font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7)).help("Collapse")
        }
    }

    private func cardHeader(pane: String) -> some View {
        HStack {
            Circle().fill(color(for: model.selectedStatus ?? .unknown)).frame(width: 7, height: 7)
            Text(agentTitle(for: pane)).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            Spacer()
            Button("Jump") { model.jumpSelected() }
                .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(.cyan)
                .help("Focus this pane in herdr + raise Ghostty")
        }
    }

    private func idleAgentSection(pane: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            cardHeader(pane: pane)
            Text(idleMessage(model.selectedStatus ?? .unknown))
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            manualDriveRow()
        }
    }

    private func idleMessage(_ status: RollupStatus) -> String {
        switch status {
        case .working: "This agent is working — nothing to answer right now. Jump to watch it drive the pane."
        case .done: "This agent finished. Jump to review its output."
        case .idle: "This agent is idle — no prompt waiting. Jump to it, or drive the pane manually."
        default: "No prompt to answer. Jump to the pane, or drive it manually."
        }
    }

    // MARK: Prompt section

    private func codexInteractionSection(pane: String,
                                         interaction: PendingInteraction) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            cardHeader(pane: pane)
            CodexInteractionView(
                interaction: interaction,
                manualText: $model.replyText,
                typeTextWithoutSubmit: model.typeTextWithoutSubmitSelected)
            manualDriveRow()
        }
    }

    @ViewBuilder
    private func promptSection(pane: String, prompt: ClassifiedPrompt) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            cardHeader(pane: pane)
            switch prompt.kind {
            case .approval: promptBody(prompt); approvalControls(prompt)
            case .question: questionSection(prompt)
            case .freeText: promptBody(prompt); rawFallbackControls()
            }
            manualDriveRow()
        }
    }

    private func manualDriveRow() -> some View {
        HStack(spacing: 5) {
            Text("Drive:").font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.4))
            rawKeyChip("↑", ["up"]); rawKeyChip("↓", ["down"])
            rawKeyChip("←", ["left"]); rawKeyChip("→", ["right"])
            rawKeyChip("↵", ["enter"]); rawKeyChip("␣", ["space"]); rawKeyChip("Esc", ["esc"])
            Spacer()
        }.padding(.top, 2)
    }

    @ViewBuilder
    private func questionSection(_ prompt: ClassifiedPrompt) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if prompt.isWizard { wizardStepBar(prompt.steps) }
            if let title = prompt.questionTitle {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            questionControls(prompt)
            if prompt.isWizard { wizardNavBar(prompt) }
        }
    }

    private func wizardStepBar(_ steps: [WizardStep]) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                Button { model.navigateToStep(index) } label: {
                    HStack(spacing: 3) {
                        Image(systemName: stepSymbol(step)).font(.system(size: 9))
                            .foregroundStyle(step.isSubmit || step.isAnswered ? .green : .white.opacity(0.5))
                        Text(step.label).font(.system(size: 10, weight: step.isCurrent ? .bold : .regular))
                            .foregroundStyle(step.isCurrent ? .white : .white.opacity(0.6))
                    }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(step.isCurrent ? Color.white.opacity(0.15) : Color.white.opacity(0.03)))
                }
                .buttonStyle(.plain).help(step.isCurrent ? "Current question" : "Go to \(step.label)")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func wizardNavBar(_ prompt: ClassifiedPrompt) -> some View {
        HStack(spacing: 8) {
            Button { model.navigateStep(-1) } label: { Label("Back", systemImage: "chevron.left").font(.system(size: 10, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(.cyan).disabled((prompt.currentStepIndex ?? 0) <= 0)
            Button { model.navigateStep(1) } label: { Label("Next", systemImage: "chevron.right").font(.system(size: 10, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(.cyan).disabled(prompt.currentStepIndex.map { $0 >= prompt.steps.count - 1 } ?? true)
            Spacer()
            Text(prompt.currentStepIndex == nil ? "Answer or use the terminal to move between questions" : "Tap a tab to jump")
                .font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
        }
    }

    private func stepSymbol(_ step: WizardStep) -> String {
        if step.isSubmit { return "paperplane" }
        if step.isAnswered { return "checkmark.square.fill" }
        return "square"
    }

    @ViewBuilder
    private func promptBody(_ prompt: ClassifiedPrompt) -> some View {
        ScrollView {
            if prompt.isMarkdown, let attributed = try? AttributedString(markdown: prompt.promptText,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                Text(attributed).font(.system(size: 11)).foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(prompt.promptText).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8)).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.frame(maxHeight: 120)
    }

    private func approvalControls(_ prompt: ClassifiedPrompt) -> some View {
        HStack(spacing: 8) {
            actionButton("Allow", "\(model.hotkeySymbols)Y", .green) { model.approveSelected() }
            actionButton("Deny", "\(model.hotkeySymbols)N", .red) { model.denySelected() }
        }
    }

    private func questionControls(_ prompt: ClassifiedPrompt) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(prompt.options.enumerated()), id: \.offset) { index, option in
                if option.isTextEntry { textEntryOption(index: index, option: option) }
                else { choiceOption(index: index, option: option) }
            }
        }
    }

    private func choiceOption(index: Int, option: PromptOption) -> some View {
        Button { model.answerSelected(index: index) } label: {
            HStack(alignment: .top, spacing: 8) {
                Text("\(index + 1).").font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(option.isSelected ? .green : .white.opacity(0.7)).monospacedDigit()
                if let checked = option.isChecked {
                    Image(systemName: checked ? "checkmark.square.fill" : "square").font(.system(size: 11))
                        .foregroundStyle(checked ? .green : .white.opacity(0.4))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).font(.system(size: 11, weight: option.isSelected ? .semibold : .regular)).foregroundStyle(.white)
                    if let description = option.description {
                        Text(description).font(.system(size: 9)).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
                if index < 9 { Text("\(model.hotkeySymbols)\(index + 1)").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.4)) }
            }
            .padding(.horizontal, 10).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(optionFill(option)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(option.isSelected ? Color.green.opacity(0.6) : .clear, lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private func optionFill(_ option: PromptOption) -> Color {
        if option.isChecked == true { return .green.opacity(0.18) }
        if option.isSelected { return .white.opacity(0.14) }
        return .white.opacity(0.08)
    }

    private func textEntryOption(index: Int, option: PromptOption) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text("\(index + 1).").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.7)).monospacedDigit()
                Text(cleanTextEntryLabel(option.label)).font(.system(size: 11)).foregroundStyle(.white)
                Spacer()
            }
            HStack(spacing: 6) {
                TextField("type your answer…", text: $model.replyText).textFieldStyle(.roundedBorder).font(.system(size: 11))
                    .onSubmit { model.submitTextOption(index: index, text: model.replyText) }
                Button("Submit") { model.submitTextOption(index: index, text: model.replyText) }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(.cyan)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.cyan.opacity(0.10)))
    }

    private func cleanTextEntryLabel(_ label: String) -> String {
        label.lowercased().contains("chat about") ? "Chat about this" : "Type something"
    }

    private func rawFallbackControls() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Unrecognized prompt — send keys/text manually").font(.system(size: 9, weight: .medium)).foregroundStyle(.orange)
            HStack(spacing: 6) {
                TextField("keys or text…", text: $model.replyText).textFieldStyle(.roundedBorder).font(.system(size: 11))
                Button("Send Text") { model.replySelected() }.buttonStyle(.plain).foregroundStyle(.cyan).font(.system(size: 11, weight: .semibold))
            }
            HStack(spacing: 5) {
                rawKeyChip("↑", ["up"]); rawKeyChip("↓", ["down"]); rawKeyChip("←", ["left"])
                rawKeyChip("→", ["right"]); rawKeyChip("↵", ["enter"]); rawKeyChip("Esc", ["esc"])
            }
        }
    }

    private func rawKeyChip(_ label: String, _ keys: [String]) -> some View {
        Button { model.sendRawKeysSelected(keys) } label: {
            Text(label).font(.system(size: 9, weight: .semibold)).padding(.horizontal, 6).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.12)))
        }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.85))
    }

    private func actionButton(_ title: String, _ shortcut: String, _ color: Color,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(shortcut).font(.system(size: 9, weight: .medium)).opacity(0.6)
            }
            .foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9).fill(color.opacity(0.35)))
        }.buttonStyle(.plain)
    }

    // MARK: Agent list

    private var agentList: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(agentRows(), id: \.paneID) { row in
                Button { model.selectPane(row.paneID) } label: {
                    HStack(spacing: 8) {
                        Circle().fill(color(for: row.status)).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.title).font(.system(size: 11, weight: row.status == .blocked ? .semibold : .regular)).foregroundStyle(.white)
                            Text(row.subtitle).font(.system(size: 9)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if row.status == .blocked { Text("needs input").font(.system(size: 8, weight: .bold)).foregroundStyle(.red) }
                        else { Text(row.status.rawValue).font(.system(size: 8)).foregroundStyle(.white.opacity(0.4)) }
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.3))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 7).fill(row.paneID == model.selectedPaneID ? Color.white.opacity(0.12) : Color.white.opacity(0.04)))
                }.buttonStyle(.plain).help("Show this agent's prompt")
            }
        }
    }

    private struct AgentRow { let paneID: String; let title: String; let subtitle: String; let status: RollupStatus }

    private func agentRows() -> [AgentRow] {
        let store = model.store
        return store.panes.values
            .filter { $0.agent != nil || store.derivedStatus(forPane: $0.paneID) != .unknown }
            .map { pane in
                let status = store.derivedStatus(forPane: pane.paneID)
                let agent = pane.displayAgent ?? pane.agent ?? "agent"
                let workspace = store.workspaces[pane.workspaceID]?.label ?? pane.workspaceID
                return AgentRow(paneID: pane.paneID, title: "\(agent) — \(workspace)", subtitle: pane.paneID, status: status)
            }
            .sorted { $0.status.precedence == $1.status.precedence ? $0.paneID < $1.paneID : $0.status.precedence > $1.status.precedence }
    }

    private func agentTitle(for pane: String) -> String {
        let info = model.store.panes[pane]
        let agent = info?.displayAgent ?? info?.agent ?? "agent"
        let workspace = model.store.workspaces[info?.workspaceID ?? ""]?.label ?? info?.workspaceID ?? ""
        return "\(agent) — \(workspace) (\(pane))"
    }

    private func color(for status: RollupStatus) -> Color {
        switch status {
        case .blocked: .red
        case .working: .orange
        case .done: .green
        case .idle: .blue
        case .unknown: .gray.opacity(0.5)
        }
    }
}

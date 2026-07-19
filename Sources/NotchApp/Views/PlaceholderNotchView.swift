import HerdrClient
import SwiftUI

struct PlaceholderNotchView: View {
    @Bindable var model: NotchViewModel
    let notchWidth: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pillHovered = false

    var body: some View {
        VStack(spacing: 0) {
            pill
            if model.isExpanded { expandedCard }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .animation(reduceMotion ? nil
            : .spring(response: 0.28, dampingFraction: 0.85),
            value: model.isExpanded)
        .onExitCommand { model.collapse() }
    }

    private var pill: some View {
        HStack(spacing: 6) {
            Circle().fill(statusColor(model.overallStatus)).frame(width: 8, height: 8)
            if let title = model.pillTaskTitle {
                Text(title).font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white).lineLimit(1).truncationMode(.middle)
                Text("\(model.attentionCount)▲")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.red).monospacedDigit()
            } else {
                Text("\(model.agentCount)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white).monospacedDigit()
            }
            if model.pillTaskTitle == nil, model.attentionCount > 0 {
                Text("\(model.attentionCount)▲").font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 12).frame(height: 24).frame(minWidth: notchWidth)
        .background(Capsule().fill(.black.opacity(pillHovered ? 0.94 : 0.85)))
        .overlay(Capsule().stroke(.white.opacity(pillHovered ? 0.18 : 0.08)))
        .scaleEffect(pillHovered && !reduceMotion ? 1.015 : 1)
        .contentShape(Capsule())
        .onHover { pillHovered = $0 }
        .onTapGesture { model.toggle() }.help("herdr agents — click to expand")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model.agentCount) agents, \(model.attentionCount) need input")
    }

    private var expandedCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 14).padding(.vertical, 11)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.connection == .unavailable { unavailableBanner }
                    AttentionListView(
                        items: model.attentionItems,
                        select: model.selectPane,
                        jump: model.jump)
                    if let paneID = model.selectedPaneID {
                        Divider().overlay(.white.opacity(0.15))
                        selectedDetail(paneID)
                    } else if model.attentionCount > 0 {
                        Text("Select an agent to answer its pending prompt.")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(.red)
                    }
                    if model.accessibilityMissing {
                        Text("Global hotkeys need Accessibility permission (System Settings › Privacy › Accessibility).")
                            .font(.system(size: 9)).foregroundStyle(.orange)
                    }
                }.padding(.horizontal, 14).padding(.bottom, 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 16).fill(.black.opacity(0.66))
        }
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.32), radius: 18, y: 8)
        .padding(.horizontal, 10).padding(.top, 6)
        .transition(reduceMotion ? .opacity
            : .opacity.combined(with: .move(edge: .top)))
    }

    private var header: some View {
        HStack {
            Text("Notch Agent").font(.headline).foregroundStyle(.white)
            Spacer()
            Button { model.selectAdjacentPane(-1) } label: { Image(systemName: "chevron.left") }
                .keyboardShortcut("[", modifiers: .command).help("Previous agent")
            Button { model.selectAdjacentPane(1) } label: { Image(systemName: "chevron.right") }
                .keyboardShortcut("]", modifiers: .command).help("Next agent")
            Button { model.collapse() } label: { Image(systemName: "chevron.up") }
                .help("Collapse")
        }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.72))
    }

    @ViewBuilder private func selectedDetail(_ paneID: String) -> some View {
        let item = model.attentionItems.first { $0.paneID == paneID }
        VStack(alignment: .leading, spacing: 9) {
            detailHeader(paneID)
            if let state = model.selectedInteractionState {
                staleDraftBanner(state)
                if let interaction = state.interaction {
                    InteractionDetailView(
                        interaction: interaction,
                        draftText: $model.replyText,
                        phase: state.phase,
                        hotkeySymbols: model.hotkeySymbols,
                        respond: model.respondToSelectedInteraction)
                } else if state.phase == .reading {
                    ProgressView("Reading live prompt…").foregroundStyle(.white.opacity(0.7))
                } else {
                    Text("No structured prompt was detected. Manual controls remain available.")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                }
                if let error = state.error {
                    errorBanner(error)
                }
            } else {
                Text(item?.status == .done
                    ? item?.summary ?? idleMessage(.done)
                    : idleMessage(model.selectedStatus ?? .unknown))
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
            }
            ManualDriveView(model: model)
        }
    }

    private func detailHeader(_ paneID: String) -> some View {
        let item = model.attentionItems.first { $0.paneID == paneID }
        return HStack {
            Circle().fill(statusColor(model.selectedStatus ?? .unknown)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(item?.title ?? paneID).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                Text([item?.agentName, item?.modelName, item?.workspaceLabel].compactMap { $0 }
                    .joined(separator: " · "))
                    .font(.system(size: 8, weight: .medium)).foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            Button("Jump") { model.jump(paneID) }.buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.cyan)
        }
    }

    @ViewBuilder private func staleDraftBanner(_ state: PaneInteractionState) -> some View {
        if state.draft.state == .stale {
            VStack(alignment: .leading, spacing: 6) {
                Text("Saved draft belongs to an earlier prompt").font(.system(size: 10, weight: .semibold))
                Text(state.draft.text).font(.system(size: 9, design: .monospaced)).lineLimit(3)
                HStack {
                    Button("Reuse draft") { model.confirmSelectedDraftReuse() }
                    Button("Discard") { model.discardSelectedDraft() }
                }.buttonStyle(.plain).foregroundStyle(.cyan)
            }.padding(8).background(RoundedRectangle(cornerRadius: 8).fill(.orange.opacity(0.16)))
                .foregroundStyle(.orange)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        Text(message).font(.system(size: 10, weight: .medium)).foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true).padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(.red.opacity(0.12)))
    }

    private var unavailableBanner: some View {
        Label("herdr isn't reachable. Is the server running?", systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 10)).foregroundStyle(.orange).padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(.orange.opacity(0.15)))
    }

    private func idleMessage(_ status: RollupStatus) -> String {
        switch status {
        case .working: "This agent is working — nothing to answer right now."
        case .done: "This agent finished. Jump to review its output."
        case .idle: "This agent is idle — no prompt is waiting."
        default: "No pending prompt was detected."
        }
    }

    private func statusColor(_ status: RollupStatus) -> Color {
        switch status {
        case .blocked: .red
        case .working: .orange
        case .done: .green
        case .idle: .blue
        case .unknown: .gray
        }
    }
}

private struct ManualDriveView: View {
    @Bindable var model: NotchViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Manual terminal controls").font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
            HStack(spacing: 6) {
                TextField("Keys or text…", text: $model.replyText)
                    .textFieldStyle(.roundedBorder).font(.system(size: 11))
                Button("Type") { model.typeTextWithoutSubmitSelected() }
                Button("Send ↵") { model.sendManualTextSelected() }
            }.buttonStyle(.plain).font(.system(size: 9, weight: .semibold)).foregroundStyle(.cyan)
            HStack(spacing: 5) {
                key("↑", "up"); key("↓", "down"); key("←", "left")
                key("→", "right"); key("↵", "enter"); key("Space", "space"); key("Esc", "esc")
            }
        }.disabled(model.isActing)
    }

    private func key(_ label: String, _ key: String) -> some View {
        Button { model.sendRawKeysSelected([key]) } label: {
            Text(label).font(.system(size: 9, weight: .semibold)).padding(.horizontal, 6).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.12)))
        }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.85))
            .accessibilityLabel("Send \(label) to selected pane")
    }
}

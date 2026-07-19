import HerdrClient
import SwiftUI

struct AttentionListView: View {
    let items: [InteractionAttentionDisplayModel]
    let select: (String) -> Void
    let jump: (String) -> Void
    @State private var hoveredPaneID: String?

    var body: some View {
        LazyVStack(spacing: 6) {
            ForEach(items) { item in
                HStack(spacing: 4) {
                    Button { select(item.paneID) } label: { row(item) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(item.accessibilityLabel)
                        .accessibilityHint("Show this agent's pending interaction")
                    Button("Jump") { jump(item.paneID) }
                        .buttonStyle(.plain).font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.cyan).padding(.horizontal, 6)
                        .accessibilityLabel("Jump to \(item.agentName), pane \(item.paneID)")
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 9).fill(
                    item.isSelected ? .white.opacity(0.14)
                        : hoveredPaneID == item.paneID
                            ? .white.opacity(0.10) : .white.opacity(0.055)))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(
                    hoveredPaneID == item.paneID ? .white.opacity(0.10) : .clear))
                .onHover { hovering in
                    hoveredPaneID = hovering ? item.paneID
                        : hoveredPaneID == item.paneID ? nil : hoveredPaneID
                }
            }
        }
    }

    private func row(_ item: InteractionAttentionDisplayModel) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color(item.status)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(item.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                    Spacer()
                    Text(item.agentName.uppercased())
                        .font(.system(size: 7, weight: .bold, design: .rounded))
                        .foregroundStyle(.cyan.opacity(0.9))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(.cyan.opacity(0.12)))
                    if let modelName = item.modelName {
                        Text(modelName)
                            .font(.system(size: 7, weight: .bold, design: .rounded))
                            .foregroundStyle(.purple.opacity(0.95)).lineLimit(1)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Capsule().fill(.purple.opacity(0.14)))
                    }
                }
                HStack {
                    Text(item.summary).font(.system(size: 9)).foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                    Spacer()
                    Text(item.stateText).font(.system(size: 8, weight: .bold))
                        .foregroundStyle(item.status == .blocked ? .red : .white.opacity(0.45))
                }
                Text(item.workspaceLabel).font(.system(size: 8))
                    .foregroundStyle(.white.opacity(0.32)).lineLimit(1)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }

    private func color(_ status: RollupStatus) -> Color {
        switch status {
        case .blocked: .red
        case .working: .orange
        case .done: .green
        case .idle: .blue
        case .unknown: .gray
        }
    }
}

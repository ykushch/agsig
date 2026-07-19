import Foundation

public struct InteractionDisplayChoice: Sendable, Equatable {
    public let index: Int
    public let kind: InteractionChoiceKind
    public let label: String
    public let description: String?
    public let shortcutKeys: [String]
    public let isSelected: Bool
    public let isChecked: Bool?

    public init(index: Int, kind: InteractionChoiceKind, label: String, description: String?,
                shortcutKeys: [String] = [], isSelected: Bool, isChecked: Bool?) {
        self.index = index
        self.kind = kind
        self.label = label
        self.description = description
        self.shortcutKeys = shortcutKeys
        self.isSelected = isSelected
        self.isChecked = isChecked
    }
}

/// Pure view data used by SwiftUI and fixture tests. Keeping this transformation
/// out of the view makes content parity testable without rendering or transport.
public struct InteractionDisplayModel: Sendable, Equatable {
    public let title: String?
    public let body: String?
    public let progressText: String?
    public let choices: [InteractionDisplayChoice]
    public let showsTextEntry: Bool
    public let showsBeginTextEntry: Bool
    public let choicesAreActionable: Bool
    public let showsCancel: Bool
    public let showsManualControls: Bool
    public let exposesStructuredSubmit: Bool
    public let approvalOnceAvailable: Bool
    public let approvalPersistChoiceIndex: Int?
    public let supportMessage: String?

    public init(interaction: PendingInteraction) {
        title = interaction.title
        body = interaction.body
        progressText = Self.progressText(interaction.progress)
        let isMultiSelect = interaction.capabilities.contains(.selectMany)
        let checked = Set(interaction.presentation.checkedChoiceIndexes)
        choices = interaction.choices.indices.map { index in
            let choice = interaction.choices[index]
            return InteractionDisplayChoice(
                index: index, kind: choice.kind, label: choice.label,
                description: choice.description, shortcutKeys: choice.shortcutKeys,
                isSelected: interaction.presentation.selectedChoiceIndex == index,
                isChecked: isMultiSelect ? checked.contains(index) : nil)
        }
        let supportsText = interaction.capabilities.contains(.enterText)
        showsTextEntry = supportsText
            && interaction.presentation.mechanism == .textEntry
        showsBeginTextEntry = supportsText
            && interaction.presentation.mechanism != .textEntry
            && interaction.kind == .question
        choicesAreActionable = interaction.presentation.mechanism != .ambiguous
            && interaction.presentation.mechanism != .manual
            && (interaction.capabilities.contains(.selectOne)
                || interaction.capabilities.contains(.selectMany))
            && interaction.kind != .approval
        showsCancel = interaction.capabilities.contains(.deny)
        showsManualControls = true
        exposesStructuredSubmit = interaction.presentation.mechanism != .ambiguous
            && interaction.presentation.mechanism != .manual
            && interaction.kind != .unknown
        approvalOnceAvailable = interaction.kind == .approval
            && interaction.presentation.mechanism == .explicitShortcut
            && interaction.choices.first?.shortcutKeys == ["y"]
        approvalPersistChoiceIndex = interaction.kind == .approval
            && interaction.presentation.mechanism == .explicitShortcut
            ? interaction.choices.indices.first {
                interaction.choices[$0].shortcutKeys == ["p"]
            } : nil
        if interaction.presentation.mechanism == .ambiguous {
            supportMessage = "Response mechanism is ambiguous — use manual controls."
        } else if interaction.kind == .unknown {
            supportMessage = "Unrecognized prompt — use manual controls."
        } else {
            supportMessage = "Responses are revalidated against the live prompt before sending."
        }
    }

    public static func progressText(_ progress: InteractionProgress?) -> String? {
        guard let progress else { return nil }
        if let current = progress.current, let total = progress.total {
            let base = "Question \(current)/\(total)"
            return progress.unanswered.map { "\(base) (\($0) unanswered)" } ?? base
        }
        return progress.unanswered.map { "\($0) unanswered questions" }
    }
}

/// Deterministic summary for one pane in the shared attention queue. This is
/// deliberately UI-framework-free so ordering, state language, summaries, and
/// accessibility can be fixture tested.
public struct InteractionAttentionDisplayModel: Identifiable, Sendable, Equatable {
    public let paneID: String
    public let agentName: String
    public let workspaceLabel: String
    public let status: RollupStatus
    public let stateText: String
    public let summary: String
    public let isSelected: Bool

    public var id: String { paneID }
    public var title: String { "\(agentName) — \(workspaceLabel)" }
    public var accessibilityLabel: String {
        "\(title), pane \(paneID), \(stateText), \(summary)"
    }

    public init(paneID: String, agentName: String, workspaceLabel: String,
                status: RollupStatus, state: PaneInteractionState?,
                isSelected: Bool) {
        self.paneID = paneID
        self.agentName = agentName
        self.workspaceLabel = workspaceLabel
        self.status = status
        self.isSelected = isSelected
        if let error = state?.error, !error.isEmpty {
            stateText = "error"
            summary = Self.oneLine(error)
        } else if state?.draft.state == .stale {
            stateText = "draft needs review"
            summary = "The saved draft belongs to an earlier prompt."
        } else if let phase = state?.phase, phase != .idle {
            stateText = phase.rawValue
            summary = switch phase {
            case .reading: "Reading the live prompt…"
            case .responding: "Revalidating and sending…"
            case .settling: "Waiting for the terminal to settle…"
            case .idle: ""
            }
        } else if let interaction = state?.interaction {
            stateText = interaction.kind == .unknown ? "manual input" : "needs input"
            let progress = InteractionDisplayModel.progressText(interaction.progress)
            summary = [progress, interaction.title, interaction.body]
                .compactMap { $0 }.map(Self.oneLine).first { !$0.isEmpty }
                ?? "Prompt is ready for review."
        } else if status == .blocked {
            stateText = "needs input"
            summary = "Reading the live prompt…"
        } else {
            stateText = status.rawValue
            summary = "No pending interaction."
        }
    }

    private static func oneLine(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}

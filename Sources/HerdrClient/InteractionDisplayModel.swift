import Foundation

public struct InteractionDisplayChoice: Sendable, Equatable {
    public let index: Int
    public let label: String
    public let description: String?
    public let isSelected: Bool
    public let isChecked: Bool?

    public init(index: Int, label: String, description: String?,
                isSelected: Bool, isChecked: Bool?) {
        self.index = index
        self.label = label
        self.description = description
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
    public let showsManualControls: Bool
    public let exposesStructuredSubmit: Bool
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
                index: index, label: choice.label, description: choice.description,
                isSelected: interaction.presentation.selectedChoiceIndex == index,
                isChecked: isMultiSelect ? checked.contains(index) : nil)
        }
        showsTextEntry = interaction.capabilities.contains(.enterText)
        showsManualControls = true
        exposesStructuredSubmit = interaction.presentation.mechanism != .ambiguous
            && interaction.presentation.mechanism != .manual
            && interaction.kind != .unknown
        if interaction.presentation.mechanism == .ambiguous {
            supportMessage = "Response mechanism is ambiguous — use manual controls."
        } else if interaction.kind == .unknown {
            supportMessage = "Unrecognized prompt — use manual controls."
        } else {
            supportMessage = "Safe response execution will revalidate this prompt before sending."
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

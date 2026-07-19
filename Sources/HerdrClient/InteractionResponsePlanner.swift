import Foundation

public enum InteractionResponseIntent: Sendable, Equatable {
    case selectChoice(Int)
    case setChoice(Int, checked: Bool)
    case enterText(String)
    case submitText(String)
    case beginTextEntry
    case clearTextEntry
    case navigatePrevious
    case navigateNext
    case submit
    case approve
    case deny
    case cancel
}

public enum InteractionResponseOperation: Sendable, Equatable {
    case sendKeys([String])
    case sendText(String)
}

public struct InteractionResponsePlan: Sendable, Equatable {
    public let operations: [InteractionResponseOperation]

    public init(operations: [InteractionResponseOperation]) {
        self.operations = operations
    }

    public static let noOp = InteractionResponsePlan(operations: [])

    /// Convenience for key-only fixture assertions and diagnostics.
    public var flattenedKeys: [String]? {
        var keys: [String] = []
        for operation in operations {
            guard case let .sendKeys(value) = operation else { return nil }
            keys.append(contentsOf: value)
        }
        return keys
    }
}

public enum InteractionPlanningError: Error, Sendable, Equatable {
    case unsupportedIntent
    case invalidChoice
    case missingCursor
    case ambiguousMechanism
    case emptyText
}

/// Pure planner. It has no client or transport dependency and therefore cannot
/// send input. M4 will invoke it only after reparsing and fingerprint validation.
public struct InteractionResponsePlanner: Sendable {
    public init() {}

    public func plan(_ intent: InteractionResponseIntent,
                     for interaction: PendingInteraction) throws -> InteractionResponsePlan {
        switch intent {
        case let .selectChoice(index):
            return try planChoice(index, for: interaction, toggle: false)
        case let .setChoice(index, checked):
            return try planCheckedChoice(index, checked: checked, for: interaction)
        case let .enterText(text):
            guard interaction.capabilities.contains(.enterText) else {
                throw InteractionPlanningError.unsupportedIntent
            }
            guard !text.isEmpty else { throw InteractionPlanningError.emptyText }
            return InteractionResponsePlan(operations: [.sendText(text)])
        case let .submitText(text):
            guard interaction.capabilities.contains(.enterText),
                  interaction.presentation.mechanism == .textEntry else {
                throw InteractionPlanningError.unsupportedIntent
            }
            guard !text.isEmpty else { throw InteractionPlanningError.emptyText }
            return InteractionResponsePlan(operations: [
                .sendText(text), .sendKeys(["enter"]),
            ])
        case .beginTextEntry:
            guard interaction.capabilities.contains(.enterText),
                  interaction.presentation.mechanism != .textEntry else {
                throw InteractionPlanningError.unsupportedIntent
            }
            return keys(["tab"])
        case .clearTextEntry:
            guard interaction.presentation.mechanism == .textEntry else {
                throw InteractionPlanningError.unsupportedIntent
            }
            return keys(["tab"])
        case .navigatePrevious:
            guard interaction.capabilities.contains(.navigateSteps) else {
                throw InteractionPlanningError.unsupportedIntent
            }
            return keys(["left"])
        case .navigateNext:
            guard interaction.capabilities.contains(.navigateSteps) else {
                throw InteractionPlanningError.unsupportedIntent
            }
            return keys(["right"])
        case .submit:
            guard interaction.presentation.mechanism != .ambiguous else {
                throw InteractionPlanningError.ambiguousMechanism
            }
            guard interaction.kind == .reviewSubmit
                    || interaction.presentation.mechanism == .textEntry else {
                throw InteractionPlanningError.unsupportedIntent
            }
            return keys(["enter"])
        case .approve:
            guard interaction.kind == .approval,
                  interaction.capabilities.contains(.approve) else {
                throw InteractionPlanningError.unsupportedIntent
            }
            guard interaction.presentation.mechanism != .ambiguous else {
                throw InteractionPlanningError.ambiguousMechanism
            }
            return try planChoice(0, for: interaction, toggle: false)
        case .deny:
            guard interaction.kind == .approval,
                  interaction.capabilities.contains(.deny) else {
                throw InteractionPlanningError.unsupportedIntent
            }
            return keys(["esc"])
        case .cancel:
            guard interaction.capabilities.contains(.deny) else {
                throw InteractionPlanningError.unsupportedIntent
            }
            return keys(["esc"])
        }
    }

    private func planChoice(_ index: Int, for interaction: PendingInteraction,
                            toggle: Bool) throws -> InteractionResponsePlan {
        guard interaction.choices.indices.contains(index) else {
            throw InteractionPlanningError.invalidChoice
        }
        switch interaction.presentation.mechanism {
        case .numberedShortcut:
            guard !toggle else { throw InteractionPlanningError.unsupportedIntent }
            return keys([String(index + 1), "enter"])
        case .arrowNavigate, .multiSelect:
            guard let cursor = interaction.presentation.selectedChoiceIndex else {
                throw InteractionPlanningError.missingCursor
            }
            let delta = index - cursor
            let movement = Array(repeating: delta >= 0 ? "down" : "up", count: abs(delta))
            return keys(movement + [toggle || interaction.presentation.mechanism == .multiSelect
                                    ? "space" : "enter"])
        case .ambiguous:
            throw InteractionPlanningError.ambiguousMechanism
        case .textEntry, .manual:
            throw InteractionPlanningError.unsupportedIntent
        }
    }

    private func planCheckedChoice(_ index: Int, checked desired: Bool,
                                   for interaction: PendingInteraction) throws -> InteractionResponsePlan {
        guard interaction.capabilities.contains(.selectMany),
              interaction.presentation.mechanism == .multiSelect else {
            throw InteractionPlanningError.unsupportedIntent
        }
        guard interaction.choices.indices.contains(index) else {
            throw InteractionPlanningError.invalidChoice
        }
        let checked = Set(interaction.presentation.checkedChoiceIndexes)
        let currentlyChecked = checked.contains(index)
        if currentlyChecked == desired { return .noOp }
        return try planChoice(index, for: interaction, toggle: true)
    }

    private func keys(_ keys: [String]) -> InteractionResponsePlan {
        InteractionResponsePlan(operations: [.sendKeys(keys)])
    }
}

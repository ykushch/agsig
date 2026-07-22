import Foundation

public enum InteractionResponseIntent: Sendable, Equatable {
    case previewChoice(Int)
    case selectChoice(Int)
    case setChoice(Int, checked: Bool)
    case enterText(String)
    case submitText(String)
    case submitChoiceText(Int, String)
    case beginTextEntry
    case clearTextEntry
    case navigatePrevious
    case navigateNext
    case navigateToStep(Int)
    case submit
    case approve
    case deny
    case cancel

    var preservesDraft: Bool {
        if case .previewChoice = self { return true }
        return false
    }
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
        case let .previewChoice(index):
            guard interaction.capabilities.contains(.selectOne),
                  interaction.presentation.mechanism == .arrowNavigate,
                  interaction.presentation.selectedChoicePreview != nil,
                  interaction.choices.indices.contains(index) else {
                throw InteractionPlanningError.unsupportedIntent
            }
            let movement = try keysToFocusChoice(index, for: interaction)
            return movement.isEmpty ? .noOp : keys(movement)
        case let .selectChoice(index):
            guard interaction.capabilities.contains(.selectOne) else {
                throw InteractionPlanningError.unsupportedIntent
            }
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
        case let .submitChoiceText(index, text):
            guard interaction.capabilities.contains(.enterText),
                  interaction.choices.indices.contains(index),
                  interaction.choices[index].kind == .textEntry else {
                throw InteractionPlanningError.unsupportedIntent
            }
            guard !text.isEmpty else { throw InteractionPlanningError.emptyText }
            let navigation = try keysToFocusChoice(index, for: interaction)
            var operations: [InteractionResponseOperation] = []
            if !navigation.isEmpty { operations.append(.sendKeys(navigation)) }
            operations += [.sendText(text), .sendKeys(["enter"])]
            return InteractionResponsePlan(operations: operations)
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
        case let .navigateToStep(index):
            guard interaction.capabilities.contains(.navigateSteps),
                  interaction.steps.indices.contains(index),
                  let current = interaction.presentation.activeStepIndex else {
                throw InteractionPlanningError.unsupportedIntent
            }
            let delta = index - current
            return keys(Array(
                repeating: delta >= 0 ? "right" : "left", count: abs(delta)))
        case .submit:
            guard interaction.presentation.mechanism != .ambiguous else {
                throw InteractionPlanningError.ambiguousMechanism
            }
            guard interaction.kind == .reviewSubmit
                    || interaction.presentation.mechanism == .textEntry
                    || (interaction.kind == .approval
                        && interaction.presentation.mechanism == .explicitShortcut
                        && interaction.presentation.selectedChoiceIndex != nil) else {
                throw InteractionPlanningError.unsupportedIntent
            }
            return keys(["enter"])
        case .approve:
            guard interaction.kind == .approval,
                  interaction.capabilities.contains(.approve) else {
                throw InteractionPlanningError.unsupportedIntent
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
        case .explicitShortcut:
            guard !toggle, !interaction.choices[index].shortcutKeys.isEmpty else {
                throw InteractionPlanningError.ambiguousMechanism
            }
            return keys(interaction.choices[index].shortcutKeys)
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

    private func keysToFocusChoice(_ index: Int,
                                   for interaction: PendingInteraction) throws -> [String] {
        switch interaction.presentation.mechanism {
        case .numberedShortcut:
            return [String(index + 1)]
        case .explicitShortcut:
            guard !interaction.choices[index].shortcutKeys.isEmpty else {
                throw InteractionPlanningError.ambiguousMechanism
            }
            return interaction.choices[index].shortcutKeys
        case .arrowNavigate:
            guard let cursor = interaction.presentation.selectedChoiceIndex else {
                throw InteractionPlanningError.missingCursor
            }
            let delta = index - cursor
            return Array(repeating: delta >= 0 ? "down" : "up", count: abs(delta))
        case .ambiguous:
            throw InteractionPlanningError.ambiguousMechanism
        case .multiSelect, .textEntry, .manual:
            throw InteractionPlanningError.unsupportedIntent
        }
    }

    private func keys(_ keys: [String]) -> InteractionResponsePlan {
        InteractionResponsePlan(operations: [.sendKeys(keys)])
    }
}

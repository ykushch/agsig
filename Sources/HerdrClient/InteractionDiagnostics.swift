import Foundation

public struct InteractionResponseProposal: Sendable, Equatable {
    public let intent: String
    public let choiceIndex: Int?
    public let stepIndex: Int?
    public let requiresText: Bool
    public let plan: InteractionResponsePlan?
    public let refusal: String?

    public init(intent: String, choiceIndex: Int? = nil,
                stepIndex: Int? = nil, requiresText: Bool = false,
                plan: InteractionResponsePlan? = nil, refusal: String? = nil) {
        self.intent = intent
        self.choiceIndex = choiceIndex
        self.stepIndex = stepIndex
        self.requiresText = requiresText
        self.plan = plan
        self.refusal = refusal
    }

    public var status: String {
        if requiresText { return "requires_text" }
        return plan == nil ? "refused" : "planned"
    }
}

/// Stable, machine-readable diagnostics for normalized interactions. Raw pane
/// captures remain separate artifacts; this model intentionally reports parsed
/// content/evidence and proposed operations rather than embedding terminal bytes.
public struct InteractionDiagnosticBuilder: Sendable {
    private let planner: InteractionResponsePlanner

    public init(planner: InteractionResponsePlanner = InteractionResponsePlanner()) {
        self.planner = planner
    }

    public func proposals(for interaction: PendingInteraction)
        -> [InteractionResponseProposal] {
        var values: [InteractionResponseProposal] = []
        for index in interaction.choices.indices {
            let choice = interaction.choices[index]
            if choice.kind == .textEntry {
                values.append(InteractionResponseProposal(
                    intent: "submit_choice_text", choiceIndex: index,
                    requiresText: true))
            } else if interaction.capabilities.contains(.selectMany) {
                let desired = !interaction.presentation.checkedChoiceIndexes.contains(index)
                values.append(proposal(
                    intent: desired ? "check_choice" : "uncheck_choice",
                    choiceIndex: index,
                    responseIntent: .setChoice(index, checked: desired),
                    interaction: interaction))
            } else {
                values.append(proposal(
                    intent: "select_choice", choiceIndex: index,
                    responseIntent: .selectChoice(index), interaction: interaction))
            }
        }
        if interaction.capabilities.contains(.enterText) {
            if interaction.presentation.mechanism == .textEntry {
                values.append(InteractionResponseProposal(
                    intent: "submit_text", requiresText: true))
            } else {
                values.append(proposal(
                    intent: "begin_text_entry", responseIntent: .beginTextEntry,
                    interaction: interaction))
            }
        }
        if interaction.capabilities.contains(.navigateSteps) {
            values.append(proposal(
                intent: "previous_step", responseIntent: .navigatePrevious,
                interaction: interaction))
            values.append(proposal(
                intent: "next_step", responseIntent: .navigateNext,
                interaction: interaction))
            for index in interaction.steps.indices {
                values.append(proposal(
                    intent: "navigate_to_step", stepIndex: index,
                    responseIntent: .navigateToStep(index), interaction: interaction))
            }
        }
        if interaction.kind == .reviewSubmit {
            values.append(proposal(
                intent: "submit", responseIntent: .submit,
                interaction: interaction))
        }
        if interaction.kind == .approval {
            values.append(proposal(
                intent: "approve", responseIntent: .approve,
                interaction: interaction))
            values.append(proposal(
                intent: "deny", responseIntent: .deny,
                interaction: interaction))
        } else if interaction.capabilities.contains(.deny) {
            values.append(proposal(
                intent: "cancel", responseIntent: .cancel,
                interaction: interaction))
        }
        return values
    }

    public func jsonValue(for interaction: PendingInteraction) -> JSONValue {
        .object([
            "schema_version": .number(1),
            "pane_id": .string(interaction.paneID),
            "agent_id": optional(interaction.evidence.agentID),
            "provider": .object([
                "kind": .string(interaction.evidence.source.rawValue),
                "id": .string(providerID(for: interaction)),
            ]),
            "adapter": interaction.evidence.source == .screen
                ? .string(interaction.evidence.providerID) : .null,
            "fingerprint": .string(interaction.fingerprint.rawValue),
            "kind": .string(interaction.kind.rawValue),
            "title": optional(interaction.title),
            "body": optional(interaction.body),
            "progress": progress(interaction.progress),
            "choices": .array(interaction.choices.enumerated().map { index, choice in
                .object([
                    "index": .number(Double(index)),
                    "kind": .string(choice.kind.rawValue),
                    "label": .string(choice.label),
                    "description": optional(choice.description),
                    "shortcut_keys": .array(choice.shortcutKeys.map(JSONValue.string)),
                ])
            }),
            "steps": .array(interaction.steps.enumerated().map { index, step in
                .object([
                    "index": .number(Double(index)),
                    "label": .string(step.label),
                    "answered": .bool(step.isAnswered),
                    "submit": .bool(step.isSubmit),
                ])
            }),
            "presentation": .object([
                "mechanism": .string(interaction.presentation.mechanism.rawValue),
                "selected_choice_index": optional(interaction.presentation.selectedChoiceIndex),
                "checked_choice_indexes": .array(interaction.presentation.checkedChoiceIndexes.map {
                    .number(Double($0))
                }),
                "active_step_index": optional(interaction.presentation.activeStepIndex),
            ]),
            "capabilities": .array(interaction.capabilities.map(\.rawValue).sorted().map(JSONValue.string)),
            "evidence": .object([
                "source": .string(interaction.evidence.source.rawValue),
                "provider_id": .string(interaction.evidence.providerID),
                "confidence": .string(interaction.evidence.confidence.rawValue),
                "pane_revision": optional(interaction.evidence.paneRevision),
            ]),
            "proposed_response_plans": .array(
                proposals(for: interaction).map(proposalJSON)),
        ])
    }

    public func text(for interaction: PendingInteraction) -> String {
        var lines = [
            "pane: \(interaction.paneID)",
            "agent: \(interaction.evidence.agentID ?? "—")",
            "provider: \(providerID(for: interaction)) (\(interaction.evidence.source.rawValue))",
            "adapter: \(interaction.evidence.source == .screen ? interaction.evidence.providerID : "—")",
            "fingerprint: \(interaction.fingerprint.rawValue)",
            "kind: \(interaction.kind.rawValue)",
            "confidence: \(interaction.evidence.confidence.rawValue)",
            "revision: \(interaction.evidence.paneRevision.map(String.init) ?? "—")",
            "mechanism: \(interaction.presentation.mechanism.rawValue)",
        ]
        if let title = interaction.title { lines.append("title: \(title)") }
        if let body = interaction.body { lines.append("body: \(body)") }
        for (index, choice) in interaction.choices.enumerated() {
            var suffix: [String] = []
            if interaction.presentation.selectedChoiceIndex == index { suffix.append("selected") }
            if interaction.presentation.checkedChoiceIndexes.contains(index) { suffix.append("checked") }
            if !choice.shortcutKeys.isEmpty {
                suffix.append("shortcut: \(choice.shortcutKeys.joined(separator: "+"))")
            }
            let state = suffix.isEmpty ? "" : " [\(suffix.joined(separator: ", "))]"
            lines.append("choice \(index + 1): \(choice.label)\(state)")
        }
        lines.append("proposed responses:")
        for proposal in proposals(for: interaction) {
            let target = proposal.choiceIndex.map { " choice=\($0 + 1)" }
                ?? proposal.stepIndex.map { " step=\($0 + 1)" } ?? ""
            if let plan = proposal.plan {
                lines.append("  \(proposal.intent)\(target): \(Self.describe(plan))")
            } else {
                lines.append("  \(proposal.intent)\(target): \(proposal.status)\(proposal.refusal.map { " (\($0))" } ?? "")")
            }
        }
        return lines.joined(separator: "\n")
    }

    public static func describe(_ plan: InteractionResponsePlan) -> String {
        if plan.operations.isEmpty { return "no operations" }
        return plan.operations.map { operation in
            switch operation {
            case let .sendKeys(keys): "keys [\(keys.joined(separator: ", "))]"
            case let .sendText(text): "text \(String(reflecting: text))"
            }
        }.joined(separator: " then ")
    }

    public static func planJSON(_ plan: InteractionResponsePlan) -> JSONValue {
        .object(["operations": .array(plan.operations.map { operation in
            switch operation {
            case let .sendKeys(keys):
                .object([
                    "operation": .string("send_keys"),
                    "keys": .array(keys.map(JSONValue.string)),
                ])
            case let .sendText(text):
                .object([
                    "operation": .string("send_text"),
                    "text": .string(text),
                ])
            }
        })])
    }

    private func proposal(intent: String, choiceIndex: Int? = nil,
                          stepIndex: Int? = nil,
                          responseIntent: InteractionResponseIntent,
                          interaction: PendingInteraction)
        -> InteractionResponseProposal {
        do {
            return InteractionResponseProposal(
                intent: intent, choiceIndex: choiceIndex, stepIndex: stepIndex,
                plan: try planner.plan(responseIntent, for: interaction))
        } catch {
            return InteractionResponseProposal(
                intent: intent, choiceIndex: choiceIndex, stepIndex: stepIndex,
                refusal: Self.errorCode(error))
        }
    }

    private func proposalJSON(_ proposal: InteractionResponseProposal) -> JSONValue {
        .object([
            "intent": .string(proposal.intent),
            "choice_index": optional(proposal.choiceIndex),
            "step_index": optional(proposal.stepIndex),
            "status": .string(proposal.status),
            "requires_text": .bool(proposal.requiresText),
            "plan": proposal.plan.map(Self.planJSON) ?? .null,
            "refusal": optional(proposal.refusal),
        ])
    }

    private func progress(_ progress: InteractionProgress?) -> JSONValue {
        guard let progress else { return .null }
        return .object([
            "current": optional(progress.current),
            "total": optional(progress.total),
            "unanswered": optional(progress.unanswered),
        ])
    }

    private func providerID(for interaction: PendingInteraction) -> String {
        interaction.evidence.source == .screen
            ? "screen-interaction-provider" : interaction.evidence.providerID
    }

    private func optional(_ value: String?) -> JSONValue {
        value.map(JSONValue.string) ?? .null
    }

    private func optional(_ value: Int?) -> JSONValue {
        value.map { .number(Double($0)) } ?? .null
    }

    public static func errorCode(_ error: Error) -> String {
        guard let error = error as? InteractionPlanningError else {
            return String(describing: error)
        }
        return switch error {
        case .unsupportedIntent: "unsupported_intent"
        case .invalidChoice: "invalid_choice"
        case .missingCursor: "missing_cursor"
        case .ambiguousMechanism: "ambiguous_mechanism"
        case .emptyText: "empty_text"
        }
    }
}

public enum InteractionDryRunStatus: String, Sendable, Equatable {
    case planned
    case stale
    case refused
}

public struct InteractionDryRunRequest: Sendable, Equatable {
    public let paneID: String
    public let agentID: String?
    public let paneRevision: UInt64?
    public let expectedFingerprint: InteractionFingerprint
    public let intent: InteractionResponseIntent

    public init(paneID: String, agentID: String?, paneRevision: UInt64?,
                expectedFingerprint: InteractionFingerprint,
                intent: InteractionResponseIntent) {
        self.paneID = paneID
        self.agentID = agentID
        self.paneRevision = paneRevision
        self.expectedFingerprint = expectedFingerprint
        self.intent = intent
    }
}

public struct InteractionDryRunResult: Sendable, Equatable {
    public let status: InteractionDryRunStatus
    public let expectedFingerprint: InteractionFingerprint
    public let freshInteraction: PendingInteraction
    public let plan: InteractionResponsePlan?
    public let refusal: String?

    public var identityMatched: Bool {
        expectedFingerprint == freshInteraction.fingerprint
    }

    public init(status: InteractionDryRunStatus,
                expectedFingerprint: InteractionFingerprint,
                freshInteraction: PendingInteraction,
                plan: InteractionResponsePlan?, refusal: String?) {
        self.status = status
        self.expectedFingerprint = expectedFingerprint
        self.freshInteraction = freshInteraction
        self.plan = plan
        self.refusal = refusal
    }
}

/// Revalidation + planning boundary for diagnostics. It intentionally owns only
/// an interaction provider and pure planner, so it has no API capable of sending
/// terminal input.
public struct InteractionDryRunner: Sendable {
    private let provider: any InteractionProviding
    private let planner: InteractionResponsePlanner

    public init(provider: any InteractionProviding,
                planner: InteractionResponsePlanner = InteractionResponsePlanner()) {
        self.provider = provider
        self.planner = planner
    }

    public func run(_ request: InteractionDryRunRequest) async throws
        -> InteractionDryRunResult {
        let fresh = try await provider.interaction(
            paneID: request.paneID, agentID: request.agentID,
            paneRevision: request.paneRevision)
        guard fresh.fingerprint == request.expectedFingerprint else {
            return InteractionDryRunResult(
                status: .stale, expectedFingerprint: request.expectedFingerprint,
                freshInteraction: fresh, plan: nil,
                refusal: "stale_interaction")
        }
        do {
            return InteractionDryRunResult(
                status: .planned, expectedFingerprint: request.expectedFingerprint,
                freshInteraction: fresh,
                plan: try planner.plan(request.intent, for: fresh), refusal: nil)
        } catch {
            return InteractionDryRunResult(
                status: .refused, expectedFingerprint: request.expectedFingerprint,
                freshInteraction: fresh, plan: nil,
                refusal: InteractionDiagnosticBuilder.errorCode(error))
        }
    }
}

public struct InteractionFixtureInspector: Sendable {
    private let classifier: PromptClassifier

    public init(classifier: PromptClassifier = PromptClassifier()) {
        self.classifier = classifier
    }

    public func inspect(directory: URL) throws -> PendingInteraction {
        let metadata = try PaneFixtureExtractor().verifyFixture(at: directory)
        let detection = try String(
            contentsOf: directory.appendingPathComponent("detection.txt"),
            encoding: .utf8)
        let visible = try String(
            contentsOf: directory.appendingPathComponent("visible.ansi"),
            encoding: .utf8)
        return classifier.classifyInteraction(
            paneID: metadata.sourceCapture.paneID,
            agent: metadata.sourceCapture.agent,
            text: detection, visibleANSIText: visible,
            paneRevision: metadata.sourceCapture.paneRevisionBefore,
            currentTabLabel: ScreenInteractionProvider.currentTabLabel(in: visible))
    }
}

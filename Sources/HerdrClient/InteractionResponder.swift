import Foundation

/// Fresh interaction acquisition boundary. Screen parsing is the first provider;
/// native providers can implement the same protocol later without changing the
/// responder or UI intent model.
public protocol InteractionProviding: Sendable {
    func interaction(paneID: String, agentID: String?,
                     paneRevision: UInt64?) async throws -> PendingInteraction
}

public enum InteractionProviderError: Error, Sendable, Equatable {
    case unreadablePane(paneID: String)
}

/// Re-reads both herdr pane views and runs the exact-agent screen adapter.
public struct ScreenInteractionProvider: InteractionProviding, Sendable {
    private let client: any RequestSending
    private let classifier: PromptClassifier

    public init(client: any RequestSending,
                classifier: PromptClassifier = PromptClassifier()) {
        self.client = client
        self.classifier = classifier
    }

    public func interaction(paneID: String, agentID: String?,
                            paneRevision: UInt64?) async throws
        -> PendingInteraction {
        let detection = try await read(paneID: paneID, source: .detection)
        let visible = try? await read(
            paneID: paneID, source: .visible, format: "ansi", stripAnsi: false)
        let currentTab = visible.flatMap(Self.currentTabLabel)
        return classifier.classifyInteraction(
            paneID: paneID, agent: agentID, text: detection,
            visibleANSIText: visible, paneRevision: paneRevision,
            currentTabLabel: currentTab)
    }

    private func read(paneID: String, source: ReadSource, format: String? = nil,
                      stripAnsi: Bool? = nil) async throws -> String {
        let params = try PaneReadParams(
            paneID: paneID, source: source, format: format,
            stripAnsi: stripAnsi).asJSONValue()
        let result = try await client.request("pane.read", params: params)
        guard let value = result["read"],
              let read = try? value.decode(PaneReadResult.self) else {
            throw InteractionProviderError.unreadablePane(paneID: paneID)
        }
        return read.text
    }

    public static func currentTabLabel(in text: String) -> String? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        for line in normalized.split(
            separator: "\n", omittingEmptySubsequences: false).reversed() {
            let value = String(line)
            guard value.contains("Submit"),
                  value.contains("☒") || value.contains("□") || value.contains("☑"),
                  !PromptClassifier.parseWizardSteps(value).isEmpty else { continue }
            if let label = PromptClassifier.highlightedTabLabel(in: value) {
                return label
            }
        }
        return nil
    }
}

public struct InteractionResponseRequest: Sendable, Equatable {
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

public struct InteractionResponseResult: Sendable, Equatable {
    /// Interaction used to compute the response plan after identity validation.
    public let validatedInteraction: PendingInteraction
    /// Last interaction observed by the responder-owned settle loop. Nil means
    /// the pane stopped being readable after input was accepted.
    public let settledInteraction: PendingInteraction?

    public init(validatedInteraction: PendingInteraction,
                settledInteraction: PendingInteraction?) {
        self.validatedInteraction = validatedInteraction
        self.settledInteraction = settledInteraction
    }
}

public enum InteractionResponderError: Error, Sendable, Equatable {
    case staleInteraction(expected: InteractionFingerprint,
                          actual: PendingInteraction)
    case unsupportedIntent(kind: InteractionKind,
                           intent: InteractionResponseIntent)
}

extension InteractionResponderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .staleInteraction:
            "The interaction changed before the response was sent. Nothing was sent."
        case .unsupportedIntent:
            "That response is not supported for this interaction."
        }
    }
}

public protocol InteractionResponding: Sendable {
    func respond(
        _ request: InteractionResponseRequest,
        onPhase: @escaping @Sendable (InteractionResponsePhase) async -> Void
    ) async throws
        -> InteractionResponseResult
}

public enum InteractionResponsePhase: Sendable, Equatable {
    case revalidating
    case sending
    case settling
}

extension InteractionResponding {
    public func respond(_ request: InteractionResponseRequest) async throws
        -> InteractionResponseResult {
        try await respond(request, onPhase: { _ in })
    }
}

/// Safety boundary for structured interaction responses.
///
/// Every call obtains a fresh interaction, verifies stable identity, plans from
/// its fresh presentation state, and only then sends validated operations.
public struct InteractionResponder: InteractionResponding, Sendable {
    public typealias Sleeper = @Sendable (UInt64) async -> Void

    private let provider: any InteractionProviding
    private let actions: Actions
    private let planner: InteractionResponsePlanner
    private let settleAttempts: Int
    private let settleDelayNanoseconds: UInt64
    private let sleep: Sleeper

    public init(provider: any InteractionProviding, actions: Actions,
                planner: InteractionResponsePlanner = InteractionResponsePlanner(),
                settleAttempts: Int = 8,
                settleDelayNanoseconds: UInt64 = 160_000_000,
                sleep: @escaping Sleeper = { duration in
                    try? await Task.sleep(nanoseconds: duration)
                }) {
        self.provider = provider
        self.actions = actions
        self.planner = planner
        self.settleAttempts = settleAttempts
        self.settleDelayNanoseconds = settleDelayNanoseconds
        self.sleep = sleep
    }

    public func respond(
        _ request: InteractionResponseRequest,
        onPhase: @escaping @Sendable (InteractionResponsePhase) async -> Void
    ) async throws
        -> InteractionResponseResult {
        await onPhase(.revalidating)
        let fresh = try await provider.interaction(
            paneID: request.paneID, agentID: request.agentID,
            paneRevision: request.paneRevision)
        guard fresh.fingerprint == request.expectedFingerprint else {
            throw InteractionResponderError.staleInteraction(
                expected: request.expectedFingerprint, actual: fresh)
        }
        try validate(request.intent, for: fresh.kind)
        let plan = try planner.plan(request.intent, for: fresh)
        await onPhase(.sending)
        for operation in plan.operations {
            switch operation {
            case let .sendKeys(keys):
                guard !keys.isEmpty else { continue }
                _ = try await actions.sendRawKeys(pane: request.paneID, keys: keys)
            case let .sendText(text):
                _ = try await actions.reply(
                    pane: request.paneID, text: text, submit: false)
            }
        }
        guard !plan.operations.isEmpty else {
            return InteractionResponseResult(
                validatedInteraction: fresh, settledInteraction: fresh)
        }
        await onPhase(.settling)
        let settled = await settle(after: fresh, request: request)
        return InteractionResponseResult(
            validatedInteraction: fresh, settledInteraction: settled)
    }

    private func validate(_ intent: InteractionResponseIntent,
                          for kind: InteractionKind) throws {
        let supported: Bool = switch kind {
        case .approval:
            switch intent {
            case .selectChoice, .approve, .deny: true
            default: false
            }
        case .question:
            switch intent {
            case .previewChoice, .selectChoice, .setChoice, .enterText, .submitText,
                 .submitChoiceText,
                 .beginTextEntry, .clearTextEntry, .navigatePrevious,
                 .navigateNext, .navigateToStep, .submit, .cancel: true
            case .approve, .deny: false
            }
        case .reviewSubmit:
            switch intent {
            case .selectChoice, .navigatePrevious, .navigateNext,
                 .navigateToStep, .submit,
                 .cancel: true
            default: false
            }
        case .freeText, .unknown:
            false
        }
        guard supported else {
            throw InteractionResponderError.unsupportedIntent(
                kind: kind, intent: intent)
        }
    }

    private func settle(after original: PendingInteraction,
                        request: InteractionResponseRequest) async
        -> PendingInteraction? {
        guard settleAttempts > 0 else { return original }
        var latest = original
        var previous: PendingInteraction?
        var stableCount = 0
        for _ in 0..<settleAttempts {
            await sleep(settleDelayNanoseconds)
            guard let next = try? await provider.interaction(
                paneID: request.paneID, agentID: request.agentID,
                paneRevision: request.paneRevision) else { return nil }
            latest = next
            if next == previous {
                stableCount += 1
            } else {
                previous = next
                stableCount = 1
            }
            if stableCount >= 2, next != original { return next }
        }
        return latest
    }
}

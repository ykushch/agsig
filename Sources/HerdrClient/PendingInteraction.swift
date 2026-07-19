import Foundation

public enum InteractionKind: String, Sendable, Equatable {
    case approval
    case question
    case reviewSubmit
    case freeText
    case unknown
}

public enum InteractionChoiceKind: String, Sendable, Equatable {
    case option
    case textEntry
    case submit
    case cancel
}

public struct InteractionChoice: Sendable, Equatable {
    public let kind: InteractionChoiceKind
    public let label: String
    public let description: String?
    /// Exact raw key sequence advertised by and verified against the provider.
    /// Empty means the choice must use the interaction's navigation mechanism.
    public let shortcutKeys: [String]

    public init(kind: InteractionChoiceKind = .option, label: String,
                description: String? = nil, shortcutKeys: [String] = []) {
        self.kind = kind
        self.label = label
        self.description = description
        self.shortcutKeys = shortcutKeys
    }
}

public struct InteractionStep: Sendable, Equatable {
    public let label: String
    public let isAnswered: Bool
    public let isSubmit: Bool

    public init(label: String, isAnswered: Bool, isSubmit: Bool) {
        self.label = label
        self.isAnswered = isAnswered
        self.isSubmit = isSubmit
    }
}

public struct InteractionProgress: Sendable, Equatable {
    public let current: Int?
    public let total: Int?
    public let unanswered: Int?

    public init(current: Int? = nil, total: Int? = nil, unanswered: Int? = nil) {
        self.current = current
        self.total = total
        self.unanswered = unanswered
    }
}

public enum InteractionMechanism: String, Sendable, Equatable {
    case numberedShortcut
    case explicitShortcut
    case arrowNavigate
    case multiSelect
    case textEntry
    case ambiguous
    case manual
}

/// Volatile screen state. None of these fields participates in stable identity.
public struct InteractionPresentation: Sendable, Equatable {
    public let selectedChoiceIndex: Int?
    public let checkedChoiceIndexes: [Int]
    public let activeStepIndex: Int?
    public let mechanism: InteractionMechanism

    public init(selectedChoiceIndex: Int? = nil, checkedChoiceIndexes: [Int] = [],
                activeStepIndex: Int? = nil, mechanism: InteractionMechanism) {
        self.selectedChoiceIndex = selectedChoiceIndex
        self.checkedChoiceIndexes = checkedChoiceIndexes.sorted()
        self.activeStepIndex = activeStepIndex
        self.mechanism = mechanism
    }
}

public enum InteractionCapability: String, Hashable, Sendable {
    case approve
    case deny
    case selectOne
    case selectMany
    case enterText
    case navigateSteps
    case manualTerminal
}

public enum InteractionSourceKind: String, Sendable, Equatable {
    case screen
    case native
}

public enum InteractionConfidence: String, Sendable, Equatable {
    case exact
    case inferred
    case fallback
}

/// Provenance and volatile capture data used for safety checks and diagnostics.
public struct InteractionEvidence: Sendable, Equatable {
    public let source: InteractionSourceKind
    public let providerID: String
    public let agentID: String?
    public let paneRevision: Int?
    public let confidence: InteractionConfidence
    public let capturedText: String?

    public init(source: InteractionSourceKind, providerID: String, agentID: String? = nil,
                paneRevision: Int? = nil, confidence: InteractionConfidence,
                capturedText: String? = nil) {
        self.source = source
        self.providerID = providerID
        self.agentID = agentID
        self.paneRevision = paneRevision
        self.confidence = confidence
        self.capturedText = capturedText
    }
}

public enum InteractionSafetyState: String, Sendable, Equatable {
    case fresh
    case responding
    case settled
    case stale
}

public struct InteractionFingerprint: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct PendingInteraction: Sendable, Equatable {
    public let paneID: String
    public let kind: InteractionKind
    public let title: String?
    public let body: String?
    public let progress: InteractionProgress?
    public let choices: [InteractionChoice]
    public let steps: [InteractionStep]
    public let presentation: InteractionPresentation
    public let capabilities: Set<InteractionCapability>
    public let evidence: InteractionEvidence
    public let safetyState: InteractionSafetyState

    public init(paneID: String, kind: InteractionKind, title: String? = nil,
                body: String? = nil, progress: InteractionProgress? = nil,
                choices: [InteractionChoice] = [], steps: [InteractionStep] = [],
                presentation: InteractionPresentation,
                capabilities: Set<InteractionCapability> = [],
                evidence: InteractionEvidence,
                safetyState: InteractionSafetyState = .fresh) {
        self.paneID = paneID
        self.kind = kind
        self.title = title
        self.body = body
        self.progress = progress
        self.choices = choices
        self.steps = steps
        self.presentation = presentation
        self.capabilities = capabilities
        self.evidence = evidence
        self.safetyState = safetyState
    }

    public var fingerprint: InteractionFingerprint {
        var fields = [paneID, kind.rawValue, Self.normalize(title), Self.normalize(body)]
        fields += [progress?.current, progress?.total, progress?.unanswered].map { $0.map(String.init) ?? "" }
        for choice in choices {
            fields += [choice.kind.rawValue, Self.normalize(choice.label),
                       Self.normalize(choice.description), choice.shortcutKeys.joined(separator: "\u{1f}")]
        }
        for step in steps {
            fields += [Self.normalize(step.label), step.isAnswered ? "1" : "0", step.isSubmit ? "1" : "0"]
        }
        let canonical = fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        return InteractionFingerprint(rawValue: SHA256Digest.hex(of: Data(canonical.utf8)))
    }

    /// Removes rendering-only differences while preserving meaningful text.
    public static func normalize(_ value: String?) -> String {
        guard let value else { return "" }
        return PromptClassifier.stripAnsi(value)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}

public enum InteractionDraftState: String, Sendable, Equatable {
    case attached
    case stale
}

public struct InteractionDraftKey: Hashable, Sendable {
    public let paneID: String
    public let fingerprint: InteractionFingerprint

    public init(paneID: String, fingerprint: InteractionFingerprint) {
        self.paneID = paneID
        self.fingerprint = fingerprint
    }
}

public struct InteractionDraft: Sendable, Equatable {
    public let key: InteractionDraftKey
    public var text: String
    public var state: InteractionDraftState
}

/// Retains drafts across redraws without ever attaching text to a changed prompt.
public struct InteractionDraftStore: Sendable {
    private var drafts: [InteractionDraftKey: InteractionDraft] = [:]
    private var visibleFingerprintByPane: [String: InteractionFingerprint] = [:]

    public init() {}

    public mutating func observe(_ interaction: PendingInteraction) {
        let paneID = interaction.paneID
        let fingerprint = interaction.fingerprint
        if let previous = visibleFingerprintByPane[paneID], previous != fingerprint {
            markStale(InteractionDraftKey(paneID: paneID, fingerprint: previous))
        }
        visibleFingerprintByPane[paneID] = fingerprint
        // A returning stale draft stays stale until confirmReuse is explicit.
    }

    public mutating func interactionDisappeared(paneID: String) {
        if let previous = visibleFingerprintByPane.removeValue(forKey: paneID) {
            markStale(InteractionDraftKey(paneID: paneID, fingerprint: previous))
        }
    }

    /// Returns false when this fingerprint has a stale draft. The caller must
    /// explicitly call `confirmReuse(for:)` before editing or submitting it.
    @discardableResult
    public mutating func setText(_ text: String, for interaction: PendingInteraction) -> Bool {
        observe(interaction)
        let key = InteractionDraftKey(paneID: interaction.paneID, fingerprint: interaction.fingerprint)
        if drafts[key]?.state == .stale { return false }
        drafts[key] = InteractionDraft(key: key, text: text, state: .attached)
        return true
    }

    public func draft(for interaction: PendingInteraction) -> InteractionDraft? {
        drafts[InteractionDraftKey(paneID: interaction.paneID, fingerprint: interaction.fingerprint)]
    }

    @discardableResult
    public mutating func confirmReuse(for interaction: PendingInteraction) -> Bool {
        let key = InteractionDraftKey(paneID: interaction.paneID, fingerprint: interaction.fingerprint)
        guard visibleFingerprintByPane[interaction.paneID] == interaction.fingerprint,
              drafts[key]?.state == .stale else { return false }
        drafts[key]?.state = .attached
        return true
    }

    private mutating func markStale(_ key: InteractionDraftKey) {
        drafts[key]?.state = .stale
    }
}

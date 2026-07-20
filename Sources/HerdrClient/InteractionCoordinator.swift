import Foundation
import Observation

public enum PaneInteractionPhase: String, Sendable, Equatable {
    case idle
    case reading
    case responding
    case settling

    public var isBusy: Bool { self != .idle }
}

public struct PaneInteractionDraft: Sendable, Equatable {
    public var text: String
    public var fingerprint: InteractionFingerprint?
    public var state: InteractionDraftState

    public init(text: String = "", fingerprint: InteractionFingerprint? = nil,
                state: InteractionDraftState = .attached) {
        self.text = text
        self.fingerprint = fingerprint
        self.state = state
    }
}

public enum InteractionRefreshReason: String, Sendable, Equatable {
    case newlyBlocked
    case selected
    case revisionChanged
    case fallbackCadence
    case explicitSelection
    case responseSettled
    case manualSettled
}

public struct PaneInteractionState: Sendable, Equatable {
    public let paneID: String
    public var agentID: String?
    public var interaction: PendingInteraction?
    public var draft: PaneInteractionDraft
    public var lastRevision: UInt64?
    public var lastReadAt: Date?
    public var lastRefreshReason: InteractionRefreshReason?
    public var error: String?
    public var phase: PaneInteractionPhase
    public var blockedSequence: UInt64

    public init(paneID: String, agentID: String? = nil,
                interaction: PendingInteraction? = nil,
                draft: PaneInteractionDraft = PaneInteractionDraft(),
                lastRevision: UInt64? = nil, lastReadAt: Date? = nil,
                lastRefreshReason: InteractionRefreshReason? = nil,
                error: String? = nil, phase: PaneInteractionPhase = .idle,
                blockedSequence: UInt64 = 0) {
        self.paneID = paneID
        self.agentID = agentID
        self.interaction = interaction
        self.draft = draft
        self.lastRevision = lastRevision
        self.lastReadAt = lastReadAt
        self.lastRefreshReason = lastRefreshReason
        self.error = error
        self.phase = phase
        self.blockedSequence = blockedSequence
    }

    public var fingerprint: InteractionFingerprint? {
        interaction?.fingerprint
    }
}

/// Minimal pane state consumed by the coordinator. Keeping StateStore out of the
/// boundary makes selection/poll/exit behavior deterministic in unit tests.
public struct InteractionPaneSnapshot: Sendable, Equatable {
    public let paneID: String
    public let agentID: String?
    public let revision: UInt64?
    public let isBlocked: Bool
    public let isWorking: Bool

    public init(paneID: String, agentID: String?, revision: UInt64?,
                isBlocked: Bool, isWorking: Bool = false) {
        self.paneID = paneID
        self.agentID = agentID
        self.revision = revision
        self.isBlocked = isBlocked
        self.isWorking = isWorking
    }
}

public struct InteractionReconcileResult: Sendable, Equatable {
    public let refreshedPaneIDs: [String]
    public let removedPaneIDs: [String]

    public init(refreshedPaneIDs: [String], removedPaneIDs: [String]) {
        self.refreshedPaneIDs = refreshedPaneIDs
        self.removedPaneIDs = removedPaneIDs
    }
}

/// Main-actor source of truth for all pane interactions. Network/parser work is
/// injected and awaited; every state mutation remains serialized on MainActor.
@Observable
@MainActor
public final class InteractionCoordinator {
    public typealias Clock = @Sendable () -> Date
    public typealias Sleeper = @Sendable (UInt64) async -> Void

    public private(set) var states: [String: PaneInteractionState] = [:]
    public private(set) var selectedPaneID: String?
    public private(set) var archivedDrafts: [String: PaneInteractionDraft] = [:]
    public private(set) var completionSummaries: [String: String] = [:]

    @ObservationIgnored private let reader: any InteractionProviding
    @ObservationIgnored private let responder: any InteractionResponding
    @ObservationIgnored private let now: Clock
    @ObservationIgnored private let sleep: Sleeper
    @ObservationIgnored private let fallbackPollInterval: Int
    @ObservationIgnored private let revisionReliable: Bool
    @ObservationIgnored private let settleAttempts: Int
    @ObservationIgnored private let settleDelayNanoseconds: UInt64
    @ObservationIgnored private var knownPanes: [String: InteractionPaneSnapshot] = [:]
    @ObservationIgnored private var refreshingGenerations: [String: UInt64] = [:]
    @ObservationIgnored private var pollIndex = 0
    @ObservationIgnored private var nextBlockedSequence: UInt64 = 0

    public init(reader: any InteractionProviding,
                responder: any InteractionResponding,
                fallbackPollInterval: Int = 4,
                revisionReliable: Bool = true,
                settleAttempts: Int = 8,
                settleDelayNanoseconds: UInt64 = 160_000_000,
                now: @escaping Clock = Date.init,
                sleep: @escaping Sleeper = { duration in
                    try? await Task.sleep(nanoseconds: duration)
                }) {
        self.reader = reader
        self.responder = responder
        self.fallbackPollInterval = max(1, fallbackPollInterval)
        self.revisionReliable = revisionReliable
        self.settleAttempts = settleAttempts
        self.settleDelayNanoseconds = settleDelayNanoseconds
        self.now = now
        self.sleep = sleep
    }

    public var attentionOrder: [String] {
        let blocked = states.values.filter {
            knownPanes[$0.paneID]?.isBlocked == true
        }
        let selected = selectedPaneID.flatMap { id in
            blocked.contains(where: { $0.paneID == id }) ? id : nil
        }
        let remaining = blocked.filter { $0.paneID != selected }.sorted {
            if $0.blockedSequence != $1.blockedSequence {
                return $0.blockedSequence > $1.blockedSequence
            }
            return $0.paneID < $1.paneID
        }.map(\.paneID)
        return selected.map { [$0] + remaining } ?? remaining
    }

    public var selectedState: PaneInteractionState? {
        selectedPaneID.flatMap { states[$0] }
    }

    public func state(for paneID: String) -> PaneInteractionState? {
        states[paneID]
    }

    @discardableResult
    public func reconcile(
        panes: [InteractionPaneSnapshot], newlyBlockedPaneIDs: [String],
        preserveSelectedResolvedPane: Bool = false,
        countsTowardFallbackCadence: Bool = true
    ) async -> InteractionReconcileResult {
        if countsTowardFallbackCadence { pollIndex += 1 }
        knownPanes = Dictionary(uniqueKeysWithValues: panes.map { ($0.paneID, $0) })
        let liveIDs = Set(panes.map(\.paneID))
        let blockedIDs = Set(panes.filter(\.isBlocked).map(\.paneID))
        let liveSummaries = completionSummaries.filter { liveIDs.contains($0.key) }
        if liveSummaries != completionSummaries {
            completionSummaries = liveSummaries
        }
        for pane in panes where pane.isBlocked || pane.isWorking {
            if completionSummaries[pane.paneID] != nil {
                completionSummaries[pane.paneID] = nil
            }
        }
        var removed: [String] = []

        for paneID in states.keys.sorted() {
            let vanished = !liveIDs.contains(paneID)
            let resolved = !blockedIDs.contains(paneID)
            guard vanished || resolved else { continue }
            archiveAndRemove(paneID)
            removed.append(paneID)
            if selectedPaneID == paneID,
               vanished || !preserveSelectedResolvedPane {
                selectedPaneID = nil
            }
        }
        if let selectedPaneID, !liveIDs.contains(selectedPaneID) {
            self.selectedPaneID = nil
        } else if let selectedPaneID, !blockedIDs.contains(selectedPaneID),
                  !preserveSelectedResolvedPane {
            self.selectedPaneID = nil
        }

        var orderedNew = newlyBlockedPaneIDs.filter { blockedIDs.contains($0) }
        for paneID in orderedNew { _ = ensureBlockedState(paneID) }
        for paneID in blockedIDs.sorted() where ensureBlockedState(paneID) {
            if !orderedNew.contains(paneID) { orderedNew.append(paneID) }
        }

        var refreshes: [(String, InteractionRefreshReason)] = []
        for paneID in orderedNew {
            appendRefresh(paneID, reason: .newlyBlocked, to: &refreshes)
        }
        for paneID in blockedIDs.sorted() {
            guard !orderedNew.contains(paneID), let pane = knownPanes[paneID],
                  let state = states[paneID], !state.phase.isBusy,
                  refreshingGenerations[paneID] != state.blockedSequence else { continue }
            if let revision = pane.revision, state.lastRevision != nil,
               revision != state.lastRevision {
                appendRefresh(paneID, reason: .revisionChanged, to: &refreshes)
            } else if countsTowardFallbackCadence,
                      pollIndex.isMultiple(of: fallbackPollInterval),
                      !revisionReliable || pane.revision == nil {
                appendRefresh(paneID, reason: .fallbackCadence, to: &refreshes)
            }
        }

        var refreshed: [String] = []
        for (paneID, reason) in refreshes {
            if await refresh(paneID: paneID, reason: reason) {
                refreshed.append(paneID)
            }
        }
        return InteractionReconcileResult(
            refreshedPaneIDs: refreshed, removedPaneIDs: removed)
    }

    public func select(paneID: String) async {
        selectedPaneID = paneID
        guard knownPanes[paneID]?.isBlocked == true else { return }
        _ = ensureBlockedState(paneID)
        _ = await refresh(paneID: paneID, reason: .explicitSelection)
    }

    public func clearSelection() { selectedPaneID = nil }

    public func completionSummary(for paneID: String) -> String? {
        completionSummaries[paneID]
    }

    public func cacheCompletionSummary(_ summary: String, paneID: String) {
        let value = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let pane = knownPanes[paneID],
              !pane.isBlocked, !pane.isWorking else { return }
        if completionSummaries[paneID] != value {
            completionSummaries[paneID] = value
        }
    }

    public func draftText(for paneID: String) -> String {
        guard let draft = states[paneID]?.draft,
              draft.state == .attached else { return "" }
        return draft.text
    }

    @discardableResult
    public func setDraftText(_ text: String, paneID: String) -> Bool {
        guard var state = states[paneID], let fingerprint = state.fingerprint else {
            return false
        }
        guard state.draft.state != .stale else {
            state.error = "This saved draft belongs to an older interaction."
            states[paneID] = state
            return false
        }
        state.draft = PaneInteractionDraft(
            text: text, fingerprint: fingerprint, state: .attached)
        states[paneID] = state
        return true
    }

    @discardableResult
    public func confirmDraftReuse(paneID: String) -> Bool {
        guard var state = states[paneID], let fingerprint = state.fingerprint,
              state.draft.state == .stale else { return false }
        state.draft.fingerprint = fingerprint
        state.draft.state = .attached
        state.error = nil
        states[paneID] = state
        return true
    }

    public func discardDraft(paneID: String) {
        clearDraft(paneID)
        archivedDrafts.removeValue(forKey: paneID)
    }

    @discardableResult
    public func respond(paneID: String,
                        intent: InteractionResponseIntent) async -> Bool {
        guard var state = states[paneID], state.phase == .idle,
              let interaction = state.interaction,
              let pane = knownPanes[paneID], pane.isBlocked else { return false }
        state.phase = .responding
        state.error = nil
        states[paneID] = state
        let generation = state.blockedSequence
        let expected = interaction.fingerprint
        let request = InteractionResponseRequest(
            paneID: paneID, agentID: pane.agentID,
            paneRevision: pane.revision,
            expectedFingerprint: expected, intent: intent)
        do {
            let result = try await responder.respond(request) { [weak self] phase in
                await self?.applyResponsePhase(phase, paneID: paneID,
                                               expected: expected,
                                               generation: generation)
            }
            guard states[paneID]?.blockedSequence == generation else { return true }
            clearDraft(paneID)
            if let settled = result.settledInteraction {
                install(interaction: settled, paneID: paneID,
                        reason: .responseSettled,
                        observedRevision: request.paneRevision)
            }
            setPhase(.idle, paneID: paneID)
            _ = await refresh(paneID: paneID, reason: .responseSettled)
            return true
        } catch let InteractionResponderError.staleInteraction(_, actual) {
            guard states[paneID]?.blockedSequence == generation else { return false }
            install(interaction: actual, paneID: paneID,
                    reason: .responseSettled,
                    observedRevision: request.paneRevision)
            setPhase(.idle, paneID: paneID)
            _ = await refresh(paneID: paneID, reason: .responseSettled)
            setError(
                "This interaction changed before the response was sent. Nothing was sent.",
                paneID: paneID)
            return false
        } catch {
            guard states[paneID]?.blockedSequence == generation else { return false }
            setPhase(.idle, paneID: paneID)
            setError(Self.message(for: error), paneID: paneID)
            return false
        }
    }

    @discardableResult
    public func performManualAction(
        paneID: String,
        operation: @escaping @Sendable () async throws -> Void
    ) async -> Bool {
        ensureStateForKnownPane(paneID)
        guard var state = states[paneID], state.phase == .idle else { return false }
        let original = state.interaction
        state.phase = .responding
        state.error = nil
        states[paneID] = state
        let generation = state.blockedSequence
        do {
            try await operation()
            guard states[paneID]?.blockedSequence == generation else { return true }
            clearDraft(paneID)
            setPhase(.settling, paneID: paneID)
            if knownPanes[paneID]?.isBlocked == true {
                await settleManual(
                    paneID: paneID, original: original,
                    generation: generation)
            }
            setPhase(.idle, paneID: paneID)
            if knownPanes[paneID]?.isBlocked != true {
                archiveAndRemove(paneID)
            }
            return true
        } catch {
            guard states[paneID]?.blockedSequence == generation else { return false }
            setPhase(.idle, paneID: paneID)
            setError(Self.message(for: error), paneID: paneID)
            return false
        }
    }

    public func setError(_ message: String?, paneID: String) {
        ensureStateForKnownPane(paneID)
        guard var state = states[paneID], state.error != message else { return }
        state.error = message
        states[paneID] = state
    }

    private func refresh(paneID: String,
                         reason: InteractionRefreshReason) async -> Bool {
        guard let pane = knownPanes[paneID], pane.isBlocked else { return false }
        _ = ensureBlockedState(paneID)
        guard var state = states[paneID], !state.phase.isBusy else { return false }
        let generation = state.blockedSequence
        guard refreshingGenerations[paneID] != generation else { return false }
        refreshingGenerations[paneID] = generation
        defer {
            if refreshingGenerations[paneID] == generation {
                refreshingGenerations[paneID] = nil
            }
        }
        let showsActivity = state.interaction == nil
        if showsActivity {
            state.phase = .reading
            states[paneID] = state
        }
        do {
            let interaction = try await reader.interaction(
                paneID: paneID, agentID: pane.agentID,
                paneRevision: pane.revision)
            guard states[paneID]?.blockedSequence == generation else { return false }
            if showsActivity {
                guard states[paneID]?.phase == .reading else { return false }
            } else {
                guard states[paneID]?.phase == .idle else { return false }
            }
            install(interaction: interaction, paneID: paneID, reason: reason,
                    observedRevision: pane.revision)
            return true
        } catch {
            guard states[paneID]?.blockedSequence == generation else { return false }
            if showsActivity {
                guard states[paneID]?.phase == .reading else { return false }
            } else {
                guard states[paneID]?.phase == .idle else { return false }
            }
            if showsActivity { setPhase(.idle, paneID: paneID) }
            setError(Self.message(for: error), paneID: paneID)
            return false
        }
    }

    private func settleManual(paneID: String,
                              original: PendingInteraction?,
                              generation: UInt64) async {
        guard settleAttempts > 0, let pane = knownPanes[paneID] else { return }
        var previous: PendingInteraction?
        var stableCount = 0
        for _ in 0..<settleAttempts {
            await sleep(settleDelayNanoseconds)
            guard states[paneID]?.blockedSequence == generation,
                  states[paneID]?.phase == .settling else { return }
            guard let interaction = try? await reader.interaction(
                paneID: paneID, agentID: pane.agentID,
                paneRevision: pane.revision) else { return }
            install(interaction: interaction, paneID: paneID,
                    reason: .manualSettled,
                    observedRevision: pane.revision,
                    preservingPhase: true)
            if interaction == previous { stableCount += 1 } else {
                previous = interaction
                stableCount = 1
            }
            if stableCount >= 2, interaction != original { return }
        }
    }

    private func install(interaction: PendingInteraction,
                         paneID: String, reason: InteractionRefreshReason,
                         observedRevision: UInt64?,
                         preservingPhase: Bool = false) {
        guard var state = states[paneID] else { return }
        if let draftFingerprint = state.draft.fingerprint,
           !state.draft.text.isEmpty,
           draftFingerprint != interaction.fingerprint {
            state.draft.state = .stale
        }
        state.agentID = knownPanes[paneID]?.agentID ?? interaction.evidence.agentID
        state.interaction = interaction
        state.lastRevision = observedRevision
        state.lastRefreshReason = reason
        state.error = nil
        if !preservingPhase { state.phase = .idle }
        guard state != states[paneID] else { return }
        state.lastReadAt = now()
        states[paneID] = state
    }

    private func applyResponsePhase(_ phase: InteractionResponsePhase,
                                    paneID: String,
                                    expected: InteractionFingerprint,
                                    generation: UInt64) {
        guard states[paneID]?.blockedSequence == generation,
              states[paneID]?.fingerprint == expected else { return }
        switch phase {
        case .revalidating, .sending: setPhase(.responding, paneID: paneID)
        case .settling: setPhase(.settling, paneID: paneID)
        }
    }

    @discardableResult
    private func ensureBlockedState(_ paneID: String) -> Bool {
        guard let pane = knownPanes[paneID], pane.isBlocked else { return false }
        if states[paneID] == nil {
            nextBlockedSequence += 1
            states[paneID] = PaneInteractionState(
                paneID: paneID, agentID: pane.agentID,
                draft: archivedDrafts.removeValue(forKey: paneID)
                    ?? PaneInteractionDraft(),
                blockedSequence: nextBlockedSequence)
            return true
        } else if states[paneID]?.agentID != pane.agentID {
            states[paneID]?.agentID = pane.agentID
        }
        return false
    }

    private func ensureStateForKnownPane(_ paneID: String) {
        guard states[paneID] == nil, let pane = knownPanes[paneID] else { return }
        states[paneID] = PaneInteractionState(
            paneID: paneID, agentID: pane.agentID,
            draft: archivedDrafts.removeValue(forKey: paneID)
                ?? PaneInteractionDraft())
    }

    private func archiveAndRemove(_ paneID: String) {
        guard var state = states.removeValue(forKey: paneID) else { return }
        if !state.draft.text.isEmpty {
            state.draft.state = .stale
            archivedDrafts[paneID] = state.draft
        }
    }

    private func clearDraft(_ paneID: String) {
        guard var state = states[paneID] else { return }
        state.draft = PaneInteractionDraft()
        states[paneID] = state
    }

    private func setPhase(_ phase: PaneInteractionPhase, paneID: String) {
        guard var state = states[paneID], state.phase != phase else { return }
        state.phase = phase
        states[paneID] = state
    }

    private func appendRefresh(
        _ paneID: String, reason: InteractionRefreshReason,
        to values: inout [(String, InteractionRefreshReason)]
    ) {
        guard !values.contains(where: { $0.0 == paneID }) else { return }
        values.append((paneID, reason))
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

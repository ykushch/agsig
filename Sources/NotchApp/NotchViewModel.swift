import Foundation
import HerdrClient
import Observation

struct NotchDisplaySnapshot: Sendable {
    let items: [InteractionAttentionDisplayModel]
    let selectedItem: InteractionAttentionDisplayModel?
}

/// Observable view-model backing the notch UI (specs 08/09).
///
/// Single source of truth for what the SwiftUI content shows. Owns the herdr
/// `StateStore`, `Actions`, and pane-keyed `InteractionCoordinator`, hydrates
/// from a snapshot on launch, consumes the live event stream, and auto-expands
/// when a pane blocks without allowing one pane to overwrite another.
@Observable
@MainActor
final class NotchViewModel {
    // MARK: Presentation

    var presentation: NotchPresentation = .compact
    var isExpanded: Bool { presentation.isExpanded }

    // MARK: Live state (from the store)

    let store = StateStore()

    /// Source of truth: selection, interactions, drafts, errors, revisions,
    /// reads, and response phases are all pane-keyed in this coordinator.
    private(set) var interactions: InteractionCoordinator

    var selectedPaneID: String? { interactions.selectedPaneID }
    var selectedInteractionState: PaneInteractionState? { interactions.selectedState }
    var selectedInteraction: PendingInteraction? {
        interactions.selectedState?.interaction
    }
    var selectedInteractionSizingIdentity: String? {
        guard let selectedPaneID else { return nil }
        let fingerprint = selectedInteraction?.fingerprint.rawValue ?? "none"
        return "\(selectedPaneID):\(fingerprint)"
    }

    var attentionItems: [InteractionAttentionDisplayModel] {
        attentionItems(at: Date())
    }

    func attentionItems(at now: Date) -> [InteractionAttentionDisplayModel] {
        let panes = store.panes.values.filter {
            $0.agent != nil || store.derivedStatus(forPane: $0.paneID) != .unknown
        }
        let attentionRank = Dictionary(uniqueKeysWithValues:
            interactions.attentionOrder.enumerated().map { ($0.element, $0.offset) })
        return panes.map { pane in
            let workspaceLabel = store.workspaces[pane.workspaceID]?.label
            let workspace = workspaceLabel ?? pane.workspaceID
            let status = store.derivedStatus(forPane: pane.paneID)
            let activeSince = status == .working
                ? store.workingSince[pane.paneID]
                : status == .blocked ? store.blockedSince[pane.paneID] : nil
            return InteractionAttentionDisplayModel(
                paneID: pane.paneID,
                taskTitle: PaneDisplayIdentity.taskTitle(
                    pane: pane, workspaceLabel: workspaceLabel),
                agentName: pane.displayAgent ?? pane.agent ?? "agent",
                modelName: PaneDisplayIdentity.modelBadge(pane: pane),
                workspaceLabel: workspace,
                status: status,
                state: interactions.state(for: pane.paneID),
                completionSummary: interactions.completionSummary(for: pane.paneID),
                activeSince: activeSince, now: now,
                isSelected: pane.paneID == selectedPaneID)
        }.sorted { left, right in
            let leftRank = attentionRank[left.paneID]
            let rightRank = attentionRank[right.paneID]
            if let leftRank, let rightRank { return leftRank < rightRank }
            if leftRank != nil { return true }
            if rightRank != nil { return false }
            if left.status.precedence != right.status.precedence {
                return left.status.precedence > right.status.precedence
            }
            return left.paneID < right.paneID
        }
    }

    func displaySnapshot(at now: Date) -> NotchDisplaySnapshot {
        let items = attentionItems(at: now)
        return NotchDisplaySnapshot(
            items: items,
            selectedItem: selectedPaneID.flatMap { selectedPaneID in
                items.first { $0.paneID == selectedPaneID }
            })
    }

    /// Rollup status of the currently-selected pane, for the card header.
    var selectedStatus: RollupStatus? {
        guard let id = selectedPaneID else { return nil }
        return store.derivedStatus(forPane: id)
    }

    /// Per-pane draft projection. Switching panes never overwrites another draft.
    var replyText: String {
        get {
            guard let pane = selectedPaneID else { return "" }
            return interactions.draftText(for: pane)
        }
        set {
            guard let pane = selectedPaneID else { return }
            _ = interactions.setDraftText(newValue, paneID: pane)
            markUserEngaged()
        }
    }

    private var globalError: String?
    var lastError: String? {
        get { interactions.selectedState?.error ?? globalError }
        set {
            if let pane = selectedPaneID {
                interactions.setError(newValue, paneID: pane)
            } else {
                globalError = newValue
            }
        }
    }

    /// True once the accessibility permission needed for global hotkeys is known
    /// to be missing (spec 09 surfaces a hint instead of silently failing).
    var accessibilityMissing: Bool = false

    /// Connection state for the robustness UX (spec 10d): drives a "herdr not
    /// running" empty state vs. a live view.
    enum Connection: Sendable, Equatable { case connecting, connected, unavailable }
    var connection: Connection = .connecting

    /// Optional sound engine + settings (injected by the app). The store is the
    /// source of truth; these are side-effects on state transitions.
    @ObservationIgnored var soundEngine: SoundEngine?
    @ObservationIgnored var settings: Settings?

    /// The configured hotkey modifier symbols (e.g. "^⌥") for UI hints. Falls back
    /// to "^⌥" if settings aren't wired yet.
    var hotkeySymbols: String { settings?.hotkeyModifier.symbols ?? "^⌥" }

    // MARK: Derived summary for the collapsed pill

    /// Worst status across all agents — drives the pill color.
    var overallStatus: RollupStatus { store.overallStatus }

    /// Count of agents needing attention (blocked) for the pill badge.
    var attentionCount: Int { store.blockedPanes.count }

    /// Total agent count (panes with a known agent) for the pill.
    var agentCount: Int { store.panes.values.filter { $0.agent != nil }.count }

    var hasAttention: Bool { attentionCount > 0 || overallStatus == .blocked }
    var hasWorkingPanes: Bool {
        store.panes.keys.contains { store.derivedStatus(forPane: $0) == .working }
    }

    /// Project/session title for the selected blocked pane, otherwise the most
    /// urgent blocked pane. Nil preserves the compact count-only idle pill.
    var pillTaskTitle: String? {
        guard hasAttention else { return nil }
        return AttentionRollupDisplay.pillTaskTitle(
            items: attentionItems, selectedPaneID: selectedPaneID)
    }

    // MARK: Dependencies

    @ObservationIgnored private var client: HerdrClient
    @ObservationIgnored private var actions: Actions
    @ObservationIgnored private var completionProvider: ScreenCompletionSummaryProvider
    @ObservationIgnored private var nativeRegistry: OpenCodePaneRegistry
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    var isActing: Bool { interactions.selectedState?.phase.isBusy == true }

    init(client: HerdrClient = HerdrClient()) {
        self.client = client
        let actions = Actions(client: client)
        let screenProvider = ScreenInteractionProvider(client: client)
        let registry = OpenCodePaneRegistry()
        let nativeClient = OpenCodeHTTPClient()
        let nativeProvider = OpenCodeNativeInteractionProvider(
            registry: registry, client: nativeClient)
        let provider = RoutedInteractionProvider(
            registry: registry, native: nativeProvider, fallback: screenProvider)
        self.actions = actions
        self.nativeRegistry = registry
        self.completionProvider = ScreenCompletionSummaryProvider(client: client)
        self.interactions = InteractionCoordinator(
            reader: provider,
            responder: RoutedInteractionResponder(
                registry: registry,
                native: OpenCodeNativeInteractionResponder(
                    registry: registry, client: nativeClient),
                fallback: InteractionResponder(
                    provider: screenProvider, actions: actions)))
    }

    /// Re-point the client at a new socket (session switch, spec 10c) and restart
    /// the event loop. `actions` is rebuilt lazily off the new client.
    func reconnect(socketPath: String?) {
        stop()
        client = HerdrClient(socketPath: socketPath)
        actions = Actions(client: client)
        let screenProvider = ScreenInteractionProvider(client: client)
        let registry = OpenCodePaneRegistry()
        let nativeClient = OpenCodeHTTPClient()
        let nativeProvider = OpenCodeNativeInteractionProvider(
            registry: registry, client: nativeClient)
        let provider = RoutedInteractionProvider(
            registry: registry, native: nativeProvider, fallback: screenProvider)
        nativeRegistry = registry
        completionProvider = ScreenCompletionSummaryProvider(client: client)
        interactions = InteractionCoordinator(
            reader: provider,
            responder: RoutedInteractionResponder(
                registry: registry,
                native: OpenCodeNativeInteractionResponder(
                    registry: registry, client: nativeClient),
                fallback: InteractionResponder(
                    provider: screenProvider, actions: actions)))
        connection = .connecting
        globalError = nil
        start()
    }

    // MARK: Lifecycle

    /// Begin driving the UI from herdr.
    ///
    /// **Primary path: snapshot polling.** herdr's snapshot always carries correct
    /// `agent_status`, but its `pane_agent_status_changed` events proved sparse/
    /// absent on the live build (a pane can sit `blocked` and never emit one). So a
    /// short-interval poll of `session.snapshot`, reconciled into the store, is the
    /// reliable status driver — this is what makes the pill actually react.
    ///
    /// **Accelerator path: events.** We still consume the event stream so that when
    /// events *do* fire, updates are instant, and so we notice new panes promptly.
    /// Both paths funnel through the store, which dedupes and diffs, so they can't
    /// double-count.
    func start() {
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                await self.pollOnce()
                let cadence = SnapshotPollingPolicy.nanoseconds(
                    isExpanded: self.isExpanded,
                    hasBlockedPanes: self.attentionCount > 0,
                    hasWorkingPanes: self.hasWorkingPanes,
                    isUnavailable: self.connection == .unavailable)
                try? await Task.sleep(nanoseconds: cadence)
            }
        }
        eventTask = Task { @MainActor in
            while !Task.isCancelled {
                // The event loop no longer owns hydration (the poll does); it just
                // opens a stream over the current panes and reacts to what arrives.
                let subs = self.store.currentSubscriptions()
                let watched = Set(self.store.panes.keys)
                let stream = self.client.events(subscriptions: { subs })
                for await raw in stream {
                    guard let event = EventEnvelope(raw) else { continue }
                    self.handle(event)
                    // A genuinely new pane → break so we resubscribe over the new
                    // set. Confirm against a fresh snapshot (herdr replays
                    // pane_created for closed panes, which would otherwise thrash).
                    if (event.event == "pane_created" || event.event == "pane_agent_detected"),
                       let pane = event.paneID, !watched.contains(pane),
                       await self.liveHasUnwatchedPane(watched: watched) {
                        break
                    }
                }
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 500_000_000)  // brief pause before resubscribe
            }
        }
    }

    /// One poll: fetch a snapshot, reconcile it, and fire side-effects for any
    /// pane that newly blocked (sound + auto-expand) — mirroring event handling.
    private func pollOnce() async {
        do {
            let result = try await client.request("session.snapshot")
            let snapValue = result["snapshot"] ?? result
            let snapshot = try snapValue.decode(Snapshot.self)
            if connection != .connected { connection = .connected }
            if globalError != nil { globalError = nil }
            let selectedBefore = selectedPaneID
            let transitions = store.reconcileTransitions(snapshot)
            _ = await reconcileInteractions(
                newlyBlocked: transitions.newlyBlockedPaneIDs)
            await captureCompletionSummaries(
                paneIDs: transitions.newlyFinishedPaneIDs)
            for _ in transitions.newlyBlockedPaneIDs {
                soundEngine?.play(.blocked)
            }
            for _ in transitions.newlyFinishedPaneIDs {
                soundEngine?.play(.done)
            }
            if !transitions.newlyBlockedPaneIDs.isEmpty,
               let target = interactions.attentionOrder.first {
                await surfaceBlockedPane(target)
            }
            if !transitions.newlyFinishedPaneIDs.isEmpty,
               settings?.autoExpandOnDone ?? false {
                showOverview()
            }
            // If an AUTO-surfaced blocked pane resolved (no longer blocked), clear
            // the card. But leave a MANUALLY-opened pane alone — the user opened it
            // deliberately (e.g. to read/jump an idle agent) and it should stay
            // until they close it.
            synchronizePresentationAfterInteractionReconcile(
                selectedBefore: selectedBefore)
            handleSelectedPaneResolutionIfNeeded()
        } catch {
            if connection != .unavailable { connection = .unavailable }
            let message = "Couldn't reach herdr — is it running?"
            if lastError != message { lastError = message }
        }
    }

    /// Apply one event to the store and fire the UI side-effects (sounds,
    /// auto-expand, card clearing).
    private func handle(_ event: EventEnvelope) {
        // The client emits this sentinel if herdr rejected the subscribe batch —
        // surface it instead of silently looping (it would otherwise never deliver
        // events). Marks the connection unavailable so the UI shows the error.
        if event.event == "__subscribe_error" {
            connection = .unavailable
            lastError = "herdr rejected the event subscription: \(event.data["message"]?.stringValue ?? "invalid_request")"
            return
        }
        let transitions = store.applyTransitions(event)
        let didBlock = !transitions.newlyBlockedPaneIDs.isEmpty
        if didBlock, event.paneID != nil {
            soundEngine?.play(.blocked)
        }
        Task { @MainActor in
            let selectedBefore = self.selectedPaneID
            _ = await self.reconcileInteractions(
                newlyBlocked: transitions.newlyBlockedPaneIDs,
                countsTowardFallbackCadence: false)
            await self.captureCompletionSummaries(
                paneIDs: transitions.newlyFinishedPaneIDs)
            self.synchronizePresentationAfterInteractionReconcile(
                selectedBefore: selectedBefore)
            self.handleSelectedPaneResolutionIfNeeded()
            if didBlock,
               let target = self.interactions.attentionOrder.first {
                await self.surfaceBlockedPane(target)
            }
        }
        // A pane that just became finished-unseen → play the done sound.
        for _ in transitions.newlyFinishedPaneIDs {
            soundEngine?.play(.done)
        }
        if !transitions.newlyFinishedPaneIDs.isEmpty,
           settings?.autoExpandOnDone ?? false { showOverview() }
        // Coordinator reconciliation above removes resolved/exited interaction
        // state without disturbing any other pane's response or refresh.
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        eventTask?.cancel()
        eventTask = nil
    }

    /// Whether a fresh snapshot contains a pane not in `watched` — used to confirm
    /// a genuine new pane before resubscribing (filters out herdr's stale
    /// `pane_created` replays of closed panes).
    private func liveHasUnwatchedPane(watched: Set<String>) async -> Bool {
        guard let result = try? await client.request("session.snapshot") else { return false }
        let snapValue = result["snapshot"] ?? result
        guard let snapshot = try? snapValue.decode(Snapshot.self) else { return false }
        return !Set(snapshot.uniquePanes.map(\.paneID)).subtracting(watched).isEmpty
    }

    /// Read + classify a blocked pane and surface it in an auto-expanded card.
    func surfaceBlockedPane(_ paneID: String) async {
        await interactions.select(paneID: paneID)
        presentation = .focused(NotchFocusContext(
            origin: .automatic, hasUserEngaged: false))
    }

    private func reconcileInteractions(
        newlyBlocked: [String],
        countsTowardFallbackCadence: Bool = true
    ) async
        -> InteractionReconcileResult {
        let paneValues = Array(store.panes.values)
        await nativeRegistry.replace(panes: paneValues)
        return await interactions.reconcile(
            panes: paneValues.map { pane in
                InteractionPaneSnapshot(
                    paneID: pane.paneID, agentID: pane.agent,
                    revision: pane.revision,
                    isBlocked: store.derivedStatus(forPane: pane.paneID) == .blocked,
                    isWorking: store.derivedStatus(forPane: pane.paneID) == .working)
            },
            newlyBlockedPaneIDs: newlyBlocked,
            preserveSelectedResolvedPane: presentation.preservesResolvedSelection,
            countsTowardFallbackCadence: countsTowardFallbackCadence)
    }

    /// One bounded tail read per newly-finished transition. Failed or empty
    /// extraction is intentionally not retried on every poll.
    private func captureCompletionSummaries(paneIDs: [String]) async {
        for paneID in paneIDs where store.panes[paneID] != nil {
            guard let summary = try? await completionProvider.completionSummary(
                paneID: paneID) else { continue }
            interactions.cacheCompletionSummary(summary, paneID: paneID)
        }
    }

    func selectPane(_ paneID: String) {
        if selectedPaneID == paneID, presentation.isFocused {
            showOverview()
            return
        }
        Task { @MainActor in
            await interactions.select(paneID: paneID)
            presentation = .focused(NotchFocusContext(
                origin: .manual, hasUserEngaged: true))
        }
    }

    func selectAdjacentPane(_ delta: Int) {
        let items = attentionItems
        guard !items.isEmpty else { return }
        let current = selectedPaneID.flatMap { id in
            items.firstIndex(where: { $0.paneID == id })
        } ?? (delta > 0 ? -1 : 0)
        let next = (current + delta + items.count) % items.count
        let paneID = items[next].paneID
        Task { @MainActor in
            await interactions.select(paneID: paneID)
            presentation = .focused(NotchFocusContext(
                origin: .manual, hasUserEngaged: true))
        }
    }

    func toggle() { isExpanded ? collapse() : showOverview() }
    func expand() { showOverview() }
    func showOverview() {
        interactions.clearSelection()
        presentation = .overview
    }
    func collapse() { presentation = .compact }
    func clearSelection() {
        showOverview()
    }

    private func markUserEngaged() {
        presentation.markUserEngaged()
    }

    private func synchronizePresentationAfterInteractionReconcile(
        selectedBefore: String?
    ) {
        guard let selectedBefore, selectedPaneID == nil else { return }
        guard store.panes[selectedBefore] == nil || presentation.isFocused else { return }
        presentation = presentation.fallbackAfterFocusedPaneEnds
    }

    private func handleSelectedPaneResolutionIfNeeded() {
        guard let selectedPaneID,
              store.derivedStatus(forPane: selectedPaneID) != .blocked,
              case .focused(let context) = presentation,
              context.origin == .automatic
        else { return }
        interactions.clearSelection()
        presentation = context.hasUserEngaged ? .overview : .compact
    }

    func approveSelected() {
        respondToSelectedInteraction(.approve)
    }
    func denySelected() {
        guard let interaction = selectedInteraction else { return }
        respondToSelectedInteraction(interaction.kind == .approval ? .deny : .cancel)
    }
    func answerSelected(index: Int) {
        respondToSelectedInteraction(
            selectedInteraction?.presentation.selectedChoicePreview == nil
                ? .selectChoice(index) : .previewChoice(index))
    }
    func replySelected() {
        guard let pane = selectedPaneID else { return }
        let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let interaction = selectedInteraction,
           interaction.kind != .unknown, interaction.kind != .freeText {
            guard interaction.presentation.mechanism == .textEntry else {
                lastError = "Open this interaction's text field before submitting text."
                return
            }
            respondToSelectedInteraction(.submitText(text))
            return
        }
        let actions = actions
        runManualAction(paneID: pane) {
            _ = try await actions.reply(pane: pane, text: text)
        }
    }
    func confirmSelectedDraftReuse() {
        guard let pane = selectedPaneID else { return }
        markUserEngaged()
        _ = interactions.confirmDraftReuse(paneID: pane)
    }
    func discardSelectedDraft() {
        guard let pane = selectedPaneID else { return }
        markUserEngaged()
        interactions.discardDraft(paneID: pane)
    }
    /// Explicit manual typing for partially supported normalized interactions.
    /// It does not press Enter; the user remains in control of submission.
    func typeTextWithoutSubmitSelected() {
        guard let pane = selectedPaneID else { return }
        let text = replyText
        guard !text.isEmpty else { return }
        let actions = actions
        runManualAction(paneID: pane) {
            _ = try await actions.reply(pane: pane, text: text, submit: false)
        }
    }
    func sendManualTextSelected() {
        guard let pane = selectedPaneID else { return }
        let text = replyText
        guard !text.isEmpty else { return }
        let actions = actions
        runManualAction(paneID: pane) {
            _ = try await actions.reply(pane: pane, text: text)
        }
    }
    func submitTextOption(index: Int, text: String) {
        guard !text.isEmpty else { return }
        respondToSelectedInteraction(.submitChoiceText(index, text))
    }
    func navigateToStep(_ index: Int) {
        respondToSelectedInteraction(.navigateToStep(index))
    }
    func navigateStep(_ delta: Int) {
        guard selectedInteraction?.capabilities.contains(.navigateSteps) == true else { return }
        respondToSelectedInteraction(delta < 0 ? .navigatePrevious : .navigateNext)
    }
    func sendArrowToSelected(_ key: String) { sendRawKeysSelected([key]) }
    func sendRawKeysSelected(_ keys: [String]) {
        guard let pane = selectedPaneID else { return }
        sendRawKeys(pane: pane, keys: keys)
    }
    private func sendRawKeys(pane: String, keys: [String]) {
        let actions = actions
        runManualAction(paneID: pane) {
            _ = try await actions.sendRawKeys(pane: pane, keys: keys)
        }
    }
    func jumpSelected() { if let pane = selectedPaneID { jump(pane) } }
    func jump(_ pane: String) {
        if pane == selectedPaneID { markUserEngaged() }
        let info = store.panes[pane]
        Task { @MainActor in
            do { _ = try await actions.jump(pane: pane, workspaceID: info?.workspaceID, tabID: info?.tabID) }
            catch { interactions.setError(String(describing: error), paneID: pane) }
        }
    }

    /// Manual/raw terminal actions deliberately remain available for fallback
    /// screens. Structured controls use `respondToSelectedInteraction` instead.
    private func runManualAction(
        paneID: String,
        _ body: @escaping @Sendable () async throws -> Void) {
        markUserEngaged()
        Task { @MainActor in
            _ = await interactions.performManualAction(
                paneID: paneID, operation: body)
        }
    }

    /// The only entry point for structured UI actions. The responder re-reads
    /// and validates stable identity before it can execute any operation.
    func respondToSelectedInteraction(_ intent: InteractionResponseIntent) {
        guard let pane = selectedPaneID else { return }
        markUserEngaged()
        Task { @MainActor in
            _ = await interactions.respond(paneID: pane, intent: intent)
        }
    }
}

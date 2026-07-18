import Foundation
import HerdrClient
import Observation

/// Collapsed vs. expanded presentation state for the notch panel.
enum NotchPresentation: Sendable {
    /// A thin pill roughly the width of the notch, showing a summary glyph/count.
    case collapsed
    /// The pill has grown into a card below the notch and accepts interaction.
    case expanded
}

/// Observable view-model backing the notch UI (specs 08/09).
///
/// Single source of truth for what the SwiftUI content shows. Owns the herdr
/// `StateStore`, `Actions`, and `PromptClassifier`, hydrates from a snapshot on
/// launch, consumes the live event stream, auto-expands when a pane blocks, and
/// caches the classified prompt for the currently-surfaced blocked pane.
@Observable
@MainActor
final class NotchViewModel {
    // MARK: Presentation

    var presentation: NotchPresentation = .collapsed
    var isExpanded: Bool { presentation == .expanded }

    // MARK: Live state (from the store)

    let store = StateStore()

    /// The pane currently surfaced in the expanded card (a blocked pane, or the
    /// one the user opened). nil when nothing needs attention.
    var selectedPaneID: String?

    /// Classified prompt for `selectedPaneID`, if it's blocked and readable. nil
    /// when the selected pane is idle/working (nothing to answer).
    var selectedPrompt: ClassifiedPrompt?

    /// True when the user manually opened the current pane from the list (vs. it
    /// auto-surfacing on a block). A manually-opened idle pane must NOT be
    /// auto-closed by the poll loop just because it isn't blocked.
    var manuallyOpened: Bool = false

    /// Rollup status of the currently-selected pane, for the card header.
    var selectedStatus: RollupStatus? {
        guard let id = selectedPaneID else { return nil }
        return store.derivedStatus(forPane: id)
    }

    /// Free-text field contents for the reply / raw-key box.
    var replyText: String = ""

    /// Last error surfaced by an action (shown as a toast; cleared on next action).
    var lastError: String?

    /// True once the accessibility permission needed for global hotkeys is known
    /// to be missing (spec 09 surfaces a hint instead of silently failing).
    var accessibilityMissing: Bool = false

    /// Connection state for the robustness UX (spec 10d): drives a "herdr not
    /// running" empty state vs. a live view.
    enum Connection: Sendable { case connecting, connected, unavailable }
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

    // MARK: Dependencies

    @ObservationIgnored private var client: HerdrClient
    @ObservationIgnored private let classifier = PromptClassifier()
    @ObservationIgnored private lazy var actions = Actions(client: client)
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// True while an action (send keys + settle) is in flight; serializes actions
    /// so overlapping key-sends can't misread each other's redraw frames.
    @ObservationIgnored private var isActing = false

    init(client: HerdrClient = HerdrClient()) {
        self.client = client
    }

    /// Re-point the client at a new socket (session switch, spec 10c) and restart
    /// the event loop. `actions` is rebuilt lazily off the new client.
    func reconnect(socketPath: String?) {
        stop()
        client = HerdrClient(socketPath: socketPath)
        actions = Actions(client: client)
        connection = .connecting
        selectedPaneID = nil
        selectedPrompt = nil
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
                try? await Task.sleep(nanoseconds: 1_500_000_000)  // 1.5s
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
            connection = .connected
            let newlyBlocked = store.reconcile(snapshot)
            // Don't mutate the surfaced card while an action is settling — the
            // action owns the card during that window (avoids clobbering its
            // fresh read or clearing it on a transient non-blocked frame).
            guard !isActing else { return }
            for pane in newlyBlocked {
                soundEngine?.play(.blocked)
                if settings?.autoExpandOnBlocked ?? true {
                    await surfaceBlockedPane(pane)
                }
            }
            // If an AUTO-surfaced blocked pane resolved (no longer blocked), clear
            // the card. But leave a MANUALLY-opened pane alone — the user opened it
            // deliberately (e.g. to read/jump an idle agent) and it should stay
            // until they close it.
            if let sel = selectedPaneID, !manuallyOpened,
               store.derivedStatus(forPane: sel) != .blocked {
                clearSelection()
            }
        } catch {
            connection = .unavailable
            lastError = "Couldn't reach herdr — is it running?"
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
        let wasDone = event.paneID.map { store.finishedUnseen.contains($0) } ?? false
        let didBlock = store.apply(event)
        if didBlock, let pane = event.paneID {
            soundEngine?.play(.blocked)
            if settings?.autoExpandOnBlocked ?? true {
                Task { @MainActor in await self.surfaceBlockedPane(pane) }
            }
        }
        // A pane that just became finished-unseen → play the done sound.
        if !wasDone, let pane = event.paneID, store.finishedUnseen.contains(pane) {
            soundEngine?.play(.done)
            if settings?.autoExpandOnDone ?? false { expand() }
        }
        // If the surfaced pane left blocked, clear the card.
        if let sel = selectedPaneID,
           store.derivedStatus(forPane: sel) != .blocked,
           event.paneID == sel {
            clearSelection()
        }
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
        selectedPrompt = await readAndClassify(paneID)
        selectedPaneID = paneID
        replyText = ""
        expand()
    }

    /// Read a pane and classify its prompt. Reads `detection` for clean prompt
    /// structure, PLUS `visible` with ANSI preserved so the classifier can detect
    /// the highlighted current wizard tab (which `detection` strips). The ANSI tab
    /// bar is spliced onto the detection text so a single classify sees both.
    private func readAndClassify(_ paneID: String) async -> ClassifiedPrompt {
        let agent = store.panes[paneID]?.agent
        do {
            let params = try PaneReadParams(paneID: paneID, source: .detection).asJSONValue()
            let result = try await client.request("pane.read", params: params)
            let text = (try? result["read"]?.decode(PaneReadResult.self))?.text ?? ""
            let currentTab = await currentTabLabel(paneID)
            let classified = classifier.classify(agent: agent, text: text, currentTabLabel: currentTab)
            if ProcessInfo.processInfo.environment["NOTCH_DEBUG_PROMPT"] == "1" {
                print("[notch] pane=\(paneID) tab=\(currentTab ?? "nil") kind=\(classified.kind)")
            }
            return classified
        } catch {
            return .rawFallback("(couldn't read prompt: \(error))")
        }
    }

    private func currentTabLabel(_ paneID: String) async -> String? {
        guard let params = try? PaneReadParams(paneID: paneID, source: .visible,
                                                format: "ansi", stripAnsi: false).asJSONValue(),
              let result = try? await client.request("pane.read", params: params),
              let text = (try? result["read"]?.decode(PaneReadResult.self))?.text else { return nil }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false).reversed() {
            let value = String(line)
            guard value.contains("Submit"), value.contains("☒") || value.contains("□") || value.contains("☑") else { continue }
            guard !PromptClassifier.parseWizardSteps(value).isEmpty else { continue }
            if let label = PromptClassifier.highlightedTabLabel(in: value) { return label }
        }
        return nil
    }

    func selectPane(_ paneID: String) {
        if selectedPaneID == paneID { clearSelection(); return }
        manuallyOpened = true
        Task { @MainActor in
            if store.derivedStatus(forPane: paneID) == .blocked { selectedPrompt = await readAndClassify(paneID) }
            else { selectedPrompt = nil }
            selectedPaneID = paneID; replyText = ""; expand()
        }
    }

    func toggle() { isExpanded ? collapse() : expand() }
    func expand() { presentation = .expanded }
    func collapse() { presentation = .collapsed }
    func clearSelection() { selectedPaneID = nil; selectedPrompt = nil; replyText = ""; manuallyOpened = false; collapse() }

    func approveSelected() {
        guard let pane = selectedPaneID, let prompt = selectedPrompt else { return }
        runAction { try await self.actions.approve(pane: pane, prompt: prompt) }
    }
    func denySelected() {
        guard let pane = selectedPaneID, let prompt = selectedPrompt else { return }
        runAction { try await self.actions.deny(pane: pane, prompt: prompt) }
    }
    func answerSelected(index: Int) {
        guard let pane = selectedPaneID else { return }
        Task { @MainActor in
            let prompt = await readAndClassify(pane)
            guard prompt.options.indices.contains(index) else { lastError = "That option is no longer available."; return }
            selectedPrompt = prompt
            runAction { try await self.actions.answer(pane: pane, prompt: prompt, optionIndex: index) }
        }
    }
    func replySelected() {
        guard let pane = selectedPaneID else { return }
        let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        runAction { try await self.actions.reply(pane: pane, text: text) }
    }
    func submitTextOption(index: Int, text: String) {
        guard let pane = selectedPaneID, let prompt = selectedPrompt,
              prompt.options.indices.contains(index), !text.isEmpty else { return }
        runAction {
            let keys = prompt.keysToAnswer(optionIndex: index).dropLast()
            if !keys.isEmpty { _ = try await self.actions.sendRawKeys(pane: pane, keys: Array(keys)) }
            _ = try await self.actions.reply(pane: pane, text: text)
            return .sent
        }
    }
    func navigateToStep(_ index: Int) {
        guard let prompt = selectedPrompt else { return }
        let keys = prompt.keysToNavigate(toStepIndex: index)
        guard !keys.isEmpty else { lastError = "Can't jump tabs right now — press ↑/↓ to focus the question first, then tap a tab."; return }
        sendRawKeysSelected(keys)
    }
    func navigateStep(_ delta: Int) {
        guard let prompt = selectedPrompt, let current = prompt.currentStepIndex else { return }
        navigateToStep(current + delta)
    }
    func sendArrowToSelected(_ key: String) { sendRawKeysSelected([key]) }
    func sendRawKeysSelected(_ keys: [String]) {
        guard let pane = selectedPaneID else { return }
        sendRawKeys(pane: pane, keys: keys)
    }
    private func sendRawKeys(pane: String, keys: [String]) {
        runAction { try await self.actions.sendRawKeys(pane: pane, keys: keys) }
    }
    func jumpSelected() { if let pane = selectedPaneID { jump(pane) } }
    func jump(_ pane: String) {
        let info = store.panes[pane]
        Task { @MainActor in
            do { _ = try await actions.jump(pane: pane, workspaceID: info?.workspaceID, tabID: info?.tabID) }
            catch { lastError = String(describing: error) }
        }
    }

    private func runAction(_ body: @escaping @MainActor () async throws -> ActionResult) {
        guard !isActing else { return }
        isActing = true; lastError = nil
        Task { @MainActor in
            defer { isActing = false }
            do {
                _ = try await body()
                replyText = ""
                await refreshPromptAfterAction()
            } catch let ActionError.keysRejected(message) { lastError = message }
            catch { lastError = String(describing: error) }
        }
    }

    private func refreshPromptAfterAction() async {
        guard let pane = selectedPaneID else { return }
        let previous = selectedPrompt
        var stable: ClassifiedPrompt?
        var count = 0
        for _ in 0..<8 {
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard selectedPaneID == pane else { return }
            if store.derivedStatus(forPane: pane) != .blocked { clearSelection(); return }
            let next = await readAndClassify(pane)
            selectedPrompt = next
            if next == stable { count += 1 } else { stable = next; count = 1 }
            if count >= 2, next != previous { return }
        }
    }
}

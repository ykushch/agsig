import Foundation
import Testing
@testable import HerdrClient

@MainActor
@Suite("State store: hydration, events, rollups")
struct StateStoreTests {
    func loadSnapshot() throws -> Snapshot {
        let value = try JSONValue.parse(Fixtures.data("snapshot.json"))
        return try (value["snapshot"] ?? value).decode(Snapshot.self)
    }

    func statusEvent(_ paneID: String, _ status: String,
                     workspace: String = "w4") -> EventEnvelope {
        EventEnvelope(.object([
            "event": .string("pane_agent_status_changed"),
            "data": .object([
                "pane_id": .string(paneID),
                "workspace_id": .string(workspace),
                "agent_status": .string(status),
            ]),
        ]))!
    }

    @Test("hydrate populates panes deduped and sets focus")
    func hydrate() throws {
        let store = StateStore()
        store.hydrate(try loadSnapshot())
        #expect(store.panes.count == 6) // 6 unique panes in the fixture
        #expect(store.focusedPaneID == "w3:p1")
        #expect(store.overallStatus == .idle) // all idle/unknown in fixture → idle wins over unknown
    }

    @Test("a pane going blocked is reported and drives overall status")
    func blockedTransition() throws {
        let store = StateStore()
        store.hydrate(try loadSnapshot())
        let didBlock = store.apply(statusEvent("w1:p1", "blocked"))
        #expect(didBlock == true)
        #expect(store.derivedStatus(forPane: "w1:p1") == .blocked)
        #expect(store.overallStatus == .blocked)
        #expect(store.blockedPanes.map(\.paneID) == ["w1:p1"])

        // A second blocked event on the same pane is not a NEW block.
        let again = store.apply(statusEvent("w1:p1", "blocked"))
        #expect(again == false)
    }

    @Test("working → idle on an unfocused pane derives done; acknowledge clears it")
    func doneDerivation() throws {
        let store = StateStore()
        store.hydrate(try loadSnapshot())
        // w1:p1 is not the focused pane (w3:p1 is).
        _ = store.apply(statusEvent("w1:p1", "working"))
        #expect(store.derivedStatus(forPane: "w1:p1") == .working)
        let finished = store.applyTransitions(statusEvent("w1:p1", "idle"))
        #expect(finished.newlyFinishedPaneIDs == ["w1:p1"])
        #expect(store.applyTransitions(statusEvent("w1:p1", "idle"))
            .newlyFinishedPaneIDs.isEmpty)
        #expect(store.derivedStatus(forPane: "w1:p1") == .done) // finished + unseen
        #expect(store.finishedUnseen.contains("w1:p1"))

        store.acknowledge("w1:p1")
        #expect(store.derivedStatus(forPane: "w1:p1") == .idle)
        #expect(!store.finishedUnseen.contains("w1:p1"))
    }

    @Test("focusing a finished pane clears its done badge")
    func focusClearsDone() throws {
        let store = StateStore()
        store.hydrate(try loadSnapshot())
        _ = store.apply(statusEvent("w1:p1", "working"))
        _ = store.apply(statusEvent("w1:p1", "idle"))
        #expect(store.derivedStatus(forPane: "w1:p1") == .done)

        let focus = EventEnvelope(.object([
            "event": .string("pane_focused"),
            "data": .object(["pane_id": .string("w1:p1")]),
        ]))!
        _ = store.apply(focus)
        #expect(store.focusedPaneID == "w1:p1")
        #expect(store.derivedStatus(forPane: "w1:p1") == .idle)
    }

    @Test("working → idle on the FOCUSED pane does not mark done (user is watching)")
    func focusedPaneNotDone() throws {
        let store = StateStore()
        store.hydrate(try loadSnapshot())
        _ = store.apply(statusEvent("w3:p1", "working", workspace: "w3"))
        _ = store.apply(statusEvent("w3:p1", "idle", workspace: "w3"))
        #expect(store.derivedStatus(forPane: "w3:p1") == .idle)
    }

    @Test("pane_exited removes the pane and its flags")
    func paneExit() throws {
        let store = StateStore()
        store.hydrate(try loadSnapshot())
        _ = store.apply(statusEvent("w1:p1", "working"))
        _ = store.apply(statusEvent("w1:p1", "idle"))
        #expect(store.finishedUnseen.contains("w1:p1"))
        let exit = EventEnvelope(.object([
            "event": .string("pane_exited"),
            "data": .object(["pane_id": .string("w1:p1")]),
        ]))!
        _ = store.apply(exit)
        #expect(store.panes["w1:p1"] == nil)
        #expect(!store.finishedUnseen.contains("w1:p1"))
    }

    @Test("output_matched is tracked as a soft signal")
    func outputMatchedSoftSignal() throws {
        let store = StateStore()
        store.hydrate(try loadSnapshot())
        let om = EventEnvelope(.object([
            "event": .string("pane_output_matched"),
            "data": .object(["pane_id": .string("w2:p1")]),
        ]))!
        _ = store.apply(om)
        #expect(store.outputMatched.contains("w2:p1"))
    }

    @Test("possiblyStuck surfaces long-working panes")
    func stuckHeuristic() throws {
        let store = StateStore()
        store.hydrate(try loadSnapshot())
        _ = store.apply(statusEvent("w1:p1", "working"))
        // Fake elapsed time by asking with a future 'now'.
        let future = Date().addingTimeInterval(400)
        #expect(store.possiblyStuckPanes(threshold: 300, now: future).contains("w1:p1"))
        #expect(store.possiblyStuckPanes(threshold: 300).isEmpty) // just started now
    }

    @Test("reconnect re-hydration is idempotent and preserves live done flags")
    func reconnectIdempotent() throws {
        let store = StateStore()
        store.hydrate(try loadSnapshot())
        _ = store.apply(statusEvent("w1:p1", "working"))
        _ = store.apply(statusEvent("w1:p1", "idle"))
        #expect(store.finishedUnseen.contains("w1:p1"))

        // Re-hydrate from a fresh (identical) snapshot: pane still exists, so its
        // done flag survives; pane count doesn't double.
        store.hydrate(try loadSnapshot())
        #expect(store.panes.count == 6)
        #expect(store.finishedUnseen.contains("w1:p1"))
    }

    @Test("re-hydration drops flags for panes that vanished")
    func reconnectDropsGoneFlags() throws {
        let store = StateStore()
        store.hydrate(try loadSnapshot())
        _ = store.apply(statusEvent("w1:p1", "working"))
        _ = store.apply(statusEvent("w1:p1", "idle"))

        // A snapshot without w1:p1.
        let reduced: JSONValue = .object([
            "focused_pane_id": .string("w3:p1"),
            "panes": .array([
                .object(["pane_id": "w3:p1", "terminal_id": "t", "workspace_id": "w3",
                         "tab_id": "w3:t1", "focused": true, "agent_status": "idle", "revision": 0]),
            ]),
        ])
        store.hydrate(try reduced.decode(Snapshot.self))
        #expect(store.panes["w1:p1"] == nil)
        #expect(!store.finishedUnseen.contains("w1:p1"))
    }

    @Test("currentSubscriptions covers per-pane status + global lifecycle")
    func subscriptions() throws {
        let store = StateStore()
        store.hydrate(try loadSnapshot())
        let subs = store.currentSubscriptions()
        let perPane = subs.filter { $0.type == "pane.agent_status_changed" }
        #expect(perPane.count == 6)
        #expect(perPane.allSatisfy { $0.paneID != nil })
        #expect(subs.contains { $0.type == "pane.agent_detected" && $0.paneID == nil })
        #expect(subs.contains { $0.type == "pane.exited" })
        // Regression: herdr requires `pane.output_matched` to be per-pane WITH a
        // `source` field. Including it as a bare global sub made herdr reject the
        // ENTIRE batch (`invalid_request` missing field pane_id) → no events ever
        // flowed → the notch never updated. It must NOT appear here unless/until we
        // model its required fields.
        #expect(!subs.contains { $0.type == "pane.output_matched" })
        // Every global sub must be one herdr accepts with only a `type`.
        let globals = subs.filter { $0.paneID == nil }.map(\.type)
        #expect(Set(globals) == ["pane.agent_detected", "pane.created", "pane.exited"])
    }

    @Test("a pane created after hydration changes the watched set (drives resubscribe)")
    func paneCreatedTriggersResubscribe() throws {
        // Regression: agents added AFTER launch were never watched because the
        // event loop froze its per-pane subscription set. The loop now resubscribes
        // when panes.keys changes; this pins that the trigger condition fires.
        let store = StateStore()
        store.hydrate(try loadSnapshot())
        let before = Set(store.panes.keys)
        let beforeSubs = store.currentSubscriptions().filter { $0.paneID != nil }.count

        let created = EventEnvelope(.object([
            "event": "pane_created",
            "data": .object([
                "pane": .object([
                    "pane_id": "w3:p9", "terminal_id": "t9", "workspace_id": "w3",
                    "tab_id": "w3:t9", "focused": false, "agent_status": "working", "revision": 0,
                    "agent": "codex",
                ]),
            ]),
        ]))!
        _ = store.apply(created)

        let after = Set(store.panes.keys)
        #expect(after != before) // topology changed → loop resubscribes
        #expect(after.contains("w3:p9"))
        // The new pane is now in the per-pane subscription set.
        let afterSubs = store.currentSubscriptions().filter { $0.paneID == "w3:p9" }
        #expect(afterSubs.count == 1)
        #expect(store.currentSubscriptions().filter { $0.paneID != nil }.count == beforeSubs + 1)
        // And a subsequent status change for that pane is now honored.
        _ = store.apply(statusEvent("w3:p9", "blocked", workspace: "w3"))
        #expect(store.derivedStatus(forPane: "w3:p9") == .blocked)
        #expect(store.overallStatus == .blocked)
    }

    @Test("pane_exited after hydration also changes the watched set")
    func paneExitedTriggersResubscribe() throws {
        let store = StateStore()
        store.hydrate(try loadSnapshot())
        let before = Set(store.panes.keys)
        let exit = EventEnvelope(.object([
            "event": "pane_exited",
            "data": .object(["pane_id": .string("w1:p1")]),
        ]))!
        _ = store.apply(exit)
        #expect(Set(store.panes.keys) != before)
        #expect(!store.panes.keys.contains("w1:p1"))
    }

    @Test("reconcile applies snapshot statuses and reports newly-blocked panes")
    func reconcileDetectsBlocked() throws {
        // The reliable status path: polling reconciles a fresh snapshot. Must detect
        // a pane that changed to blocked since the last snapshot (herdr's status
        // events can be absent, so this is what actually drives the pill).
        let store = StateStore()
        store.hydrate(try loadSnapshot()) // w1:p1 starts idle
        #expect(store.derivedStatus(forPane: "w1:p1") == .idle)

        // A new snapshot where w1:p1 is now blocked.
        let blockedSnap = try snapshotWith(paneID: "w1:p1", status: "blocked")
        let newlyBlocked = store.reconcile(blockedSnap)
        #expect(newlyBlocked.contains("w1:p1"))
        #expect(store.derivedStatus(forPane: "w1:p1") == .blocked)
        #expect(store.overallStatus == .blocked)

        // Reconciling the same blocked snapshot again is NOT a new block (no double sound).
        let again = store.reconcile(blockedSnap)
        #expect(!again.contains("w1:p1"))
    }

    @Test("reconciling an identical snapshot does not publish a store change")
    func identicalReconcileIsSilent() throws {
        let store = StateStore()
        let snapshot = try loadSnapshot()
        store.hydrate(snapshot)
        let revisionBefore = store.revision

        let transitions = store.reconcileTransitions(snapshot)

        #expect(transitions == StateTransitionResult())
        #expect(store.revision == revisionBefore)
    }

    @Test("reconcile still publishes non-status pane metadata changes")
    func reconcilePublishesMetadataChanges() throws {
        let store = StateStore()
        let snapshot = try loadSnapshot()
        store.hydrate(snapshot)
        let revisionBefore = store.revision
        let panes = snapshot.panes.map { pane in
            guard pane.paneID == "w1:p1" else { return pane }
            return PaneInfo(
                paneID: pane.paneID, terminalID: pane.terminalID,
                workspaceID: pane.workspaceID, tabID: pane.tabID,
                focused: pane.focused, agentStatus: pane.agentStatus,
                revision: pane.revision, agent: pane.agent,
                displayAgent: pane.displayAgent, customStatus: pane.customStatus,
                label: "renamed task", title: pane.title, cwd: pane.cwd,
                foregroundCwd: pane.foregroundCwd, scroll: pane.scroll,
                tokens: pane.tokens)
        }
        let changed = Snapshot(
            version: snapshot.version, protocol: snapshot.protocol,
            focusedWorkspaceID: snapshot.focusedWorkspaceID,
            focusedTabID: snapshot.focusedTabID,
            focusedPaneID: snapshot.focusedPaneID,
            workspaces: snapshot.workspaces, tabs: snapshot.tabs,
            panes: panes, agents: snapshot.agents)

        _ = store.reconcileTransitions(changed)

        #expect(store.panes["w1:p1"]?.label == "renamed task")
        #expect(store.revision == revisionBefore + 1)
    }

    @Test("reconcile derives done on working→idle and drops vanished panes")
    func reconcileDoneAndVanish() throws {
        let store = StateStore()
        store.hydrate(try loadSnapshot())
        _ = store.reconcileTransitions(
            try snapshotWith(paneID: "w1:p1", status: "working"))
        #expect(store.derivedStatus(forPane: "w1:p1") == .working)
        // working → idle on an unfocused pane derives done.
        let finished = store.reconcileTransitions(
            try snapshotWith(paneID: "w1:p1", status: "idle"))
        #expect(finished.newlyFinishedPaneIDs == ["w1:p1"])
        #expect(finished.newlyBlockedPaneIDs.isEmpty)
        #expect(store.reconcileTransitions(
            try snapshotWith(paneID: "w1:p1", status: "idle"))
            .newlyFinishedPaneIDs.isEmpty)
        #expect(store.derivedStatus(forPane: "w1:p1") == .done)

        // A snapshot missing w1:p1 drops it entirely.
        let empty: JSONValue = .object([
            "focused_pane_id": .string("w3:p1"),
            "panes": .array([
                .object(["pane_id": "w3:p1", "terminal_id": "t", "workspace_id": "w3",
                         "tab_id": "w3:t1", "focused": true, "agent_status": "idle", "revision": 0]),
            ]),
        ])
        _ = store.reconcile(try empty.decode(Snapshot.self))
        #expect(store.panes["w1:p1"] == nil)
    }

    /// Build a snapshot from the fixture but override one pane's status.
    func snapshotWith(paneID: String, status: String) throws -> Snapshot {
        let value = try JSONValue.parse(Fixtures.data("snapshot.json"))
        var snap = (value["snapshot"] ?? value).objectValue ?? [:]
        if var panes = snap["panes"]?.arrayValue {
            panes = panes.map { p in
                var obj = p.objectValue ?? [:]
                if obj["pane_id"]?.stringValue == paneID { obj["agent_status"] = .string(status) }
                return .object(obj)
            }
            snap["panes"] = .array(panes)
        }
        return try JSONValue.object(snap).decode(Snapshot.self)
    }

    @Test("tab and workspace rollups use blocked>working>done>idle precedence")
    func rollups() throws {
        let store = StateStore()
        store.hydrate(try loadSnapshot())
        // w652cb9b5bdfa32 has 3 panes (p1 idle, p2 unknown, p3 unknown). Block p3.
        _ = store.apply(statusEvent("w652cb9b5bdfa32:p3", "blocked", workspace: "w652cb9b5bdfa32"))
        #expect(store.rollup(forWorkspace: "w652cb9b5bdfa32") == .blocked)
        #expect(store.rollup(forTab: "w652cb9b5bdfa32:t2") == .blocked)
    }
}

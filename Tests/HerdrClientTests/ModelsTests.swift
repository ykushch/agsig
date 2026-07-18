import Foundation
import Testing
@testable import HerdrClient

@Suite("Model decoding from M0 fixtures")
struct ModelsTests {
    @Test("session.snapshot fixture decodes with key fields intact")
    func snapshotDecodes() throws {
        let value = try JSONValue.parse(Fixtures.data("snapshot.json"))
        // Envelope is nested: result-less fixture is the raw {type, snapshot:{…}}.
        let snapValue = value["snapshot"] ?? value
        let snap = try snapValue.decode(Snapshot.self)

        #expect(snap.protocol == 16)
        #expect(snap.focusedPaneID == "w3:p1")
        #expect(snap.workspaces.count == 4)
        #expect(snap.tabs.count == 5)
        // The fixture repeats no panes here, but uniquePanes must be safe regardless.
        #expect(snap.uniquePanes.count == snap.panes.count)

        let w3p1 = snap.uniquePanes.first { $0.paneID == "w3:p1" }
        #expect(w3p1 != nil)
        #expect(w3p1?.agent == "claude")
        #expect(w3p1?.agentStatus == .idle)
        #expect(w3p1?.focused == true)
        #expect(w3p1?.scroll?.viewportRows == 77)

        // A pane with no `agent` field must still decode (optional).
        let noAgent = snap.uniquePanes.first { $0.paneID == "w652cb9b5bdfa32:p2" }
        #expect(noAgent != nil)
        #expect(noAgent?.agent == nil)
        #expect(noAgent?.agentStatus == .unknown)
    }

    @Test("snapshot round-trips (decode → encode → decode) without losing required fields")
    func snapshotRoundTrips() throws {
        let value = try JSONValue.parse(Fixtures.data("snapshot.json"))
        let snap = try (value["snapshot"] ?? value).decode(Snapshot.self)
        let reEncoded = try JSONValue.parse(try JSONEncoder().encode(snap))
        let snap2 = try reEncoded.decode(Snapshot.self)
        #expect(snap2.panes.count == snap.panes.count)
        #expect(snap2.focusedPaneID == snap.focusedPaneID)
    }

    @Test("uniquePanes dedups repeated pane_ids")
    func dedupPanes() throws {
        let json: JSONValue = .object([
            "panes": .array([
                .object(["pane_id": "w1:p1", "terminal_id": "t1", "workspace_id": "w1",
                         "tab_id": "w1:t1", "focused": false, "agent_status": "idle", "revision": 0]),
                .object(["pane_id": "w1:p1", "terminal_id": "t1", "workspace_id": "w1",
                         "tab_id": "w1:t1", "focused": false, "agent_status": "working", "revision": 1]),
            ]),
        ])
        let snap = try json.decode(Snapshot.self)
        #expect(snap.panes.count == 2)
        #expect(snap.uniquePanes.count == 1)
    }

    @Test("unknown agent_status maps to .unknown, never throws")
    func unknownStatusTolerant() throws {
        let json: JSONValue = .object([
            "pane_id": "w1:p1", "terminal_id": "t1", "workspace_id": "w1",
            "tab_id": "w1:t1", "focused": false,
            "agent_status": "some_future_state", "revision": 0,
        ])
        let pane = try json.decode(PaneInfo.self)
        #expect(pane.agentStatus == .unknown)
    }

    @Test("unknown top-level fields are ignored, not fatal")
    func unknownFieldsIgnored() throws {
        let json: JSONValue = .object([
            "pane_id": "w1:p1", "terminal_id": "t1", "workspace_id": "w1",
            "tab_id": "w1:t1", "focused": false, "agent_status": "idle", "revision": 0,
            "some_new_field": "value", "another": .object(["nested": true]),
        ])
        let pane = try json.decode(PaneInfo.self)
        #expect(pane.paneID == "w1:p1")
    }

    @Test("PaneAgentState has no done")
    func paneStateNoDone() {
        #expect(PaneAgentState(rawValue: "done") == nil)
        #expect(AgentStatus(rawValue: "done") == .done)
    }

    @Test("event envelope: agent_status_changed decodes typed data")
    func eventEnvelope() throws {
        let raw: JSONValue = .object([
            "event": "pane_agent_status_changed",
            "data": .object([
                "pane_id": "w1:p1",
                "workspace_id": "w1",
                "agent_status": "blocked",
                "agent": "claude",
            ]),
        ])
        let env = EventEnvelope(raw)
        #expect(env != nil)
        #expect(env?.event == "pane_agent_status_changed")
        #expect(env?.paneID == "w1:p1")
        #expect(env?.agentStatus == .blocked)

        let typed = try env!.data.decode(PaneAgentStatusChangedEvent.self)
        #expect(typed.paneID == "w1:p1")
        #expect(typed.agentStatus == .blocked)
        #expect(typed.agent == "claude")
    }

    @Test("event envelope with pane payload decodes PaneInfo")
    func eventWithPane() throws {
        let raw: JSONValue = .object([
            "event": "pane_created",
            "data": .object([
                "pane": .object([
                    "pane_id": "w2:p1", "terminal_id": "t9", "workspace_id": "w2",
                    "tab_id": "w2:t1", "focused": true, "agent_status": "idle", "revision": 0,
                ]),
            ]),
        ])
        let env = EventEnvelope(raw)
        #expect(env?.pane?.paneID == "w2:p1")
        #expect(env?.pane?.focused == true)
    }

    @Test("paneID resolves from a nested pane body (pane_created), not just data.pane_id")
    func paneIDFromNestedBody() throws {
        // Regression: `pane_created`/`pane_focused` nest the id at data.pane.pane_id,
        // NOT data.pane_id. If paneID only read the top level it returned nil, so the
        // resubscribe-on-new-pane trigger never fired and new agents were never
        // watched (the notch never reacted to them).
        let created: JSONValue = .object([
            "event": "pane_created",
            "data": .object([
                "pane": .object([
                    "pane_id": "w3:p9", "terminal_id": "t", "workspace_id": "w3",
                    "tab_id": "w3:t9", "focused": false, "agent_status": "unknown", "revision": 0,
                ]),
            ]),
        ])
        #expect(EventEnvelope(created)?.paneID == "w3:p9")

        // And the flat form still works.
        let status: JSONValue = .object([
            "event": "pane_agent_status_changed",
            "data": .object(["pane_id": "w1:p1", "agent_status": "blocked"]),
        ])
        #expect(EventEnvelope(status)?.paneID == "w1:p1")
    }

    @Test("pane.read result shape decodes text")
    func readResult() throws {
        let raw: JSONValue = .object([
            "read": .object([
                "text": .string("Do you want to proceed?"),
                "source": "detection",
                "pane_id": "w1:p1",
            ]),
        ])
        let result = try raw["read"]!.decode(PaneReadResult.self)
        #expect(result.text == "Do you want to proceed?")
        #expect(result.source == "detection")
    }

    @Test("param structs encode to expected wire shape")
    func paramEncoding() throws {
        let keys = PaneSendKeysParams(paneID: "w1:p1", keys: ["1", "enter"])
        let value = try keys.asJSONValue()
        #expect(value["pane_id"]?.stringValue == "w1:p1")
        #expect(value["keys"]?.arrayValue?.compactMap(\.stringValue) == ["1", "enter"])

        let read = PaneReadParams(paneID: "w1:p1", source: .recentUnwrapped)
        let readValue = try read.asJSONValue()
        #expect(readValue["source"]?.stringValue == "recent_unwrapped")
    }
}

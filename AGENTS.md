# NotchAgent — build & architecture notes for Claude

A native macOS notch/menu-bar control surface for AI coding agents running under
[herdr](https://herdr.dev), viewed and driven from Ghostty. herdr is the state
authority; this app is a **socket client + notch UI**. See `../notch-agent-control-plane.md`
(design) and `../execution-plan.md` (milestones); atomic tasks live in `../specs/`.

## Build & test

```bash
swift build                      # build all targets
swift build --target HerdrClient # build just the core library (fast lane)
swift test                       # run the full swift-testing suite (needs ALL targets to compile)
swift run notchctl list          # dogfood the core against live herdr
swift run NotchApp               # launch the notch UI (accessory app; no dock icon)
```

- **Toolchain:** Swift 6.2, macOS 14+. No third-party dependencies (Foundation/AppKit/SwiftUI + POSIX sockets only).
- `swift test` compiles *every* target first — a broken UI target blocks core tests. Use `swift build --target HerdrClient`/`--target HerdrClientTests` to verify the core in isolation.
- Tests use the **swift-testing** framework (`import Testing`, `@Test`/`@Suite`/`#expect`), NOT XCTest. `xcrun xctest` will report "0 tests" — always use `swift test`.

## Targets

| Target | Kind | Contents |
| --- | --- | --- |
| `HerdrClient` | library | Socket client, Codable models, state store, prompt classifier, action layer. The whole M1 core. |
| `notchctl` | executable | Headless CLI harness that dogfoods the core (`list`/`watch`/`read`/`resolve`/`reply`/`jump`). |
| `NotchApp` | executable | The notch `NSPanel` UI (accessory app). Binds to `HerdrClient`. |

## Architecture (data flow)

```
herdr server (owns PTYs + agent state)
    │ newline-delimited JSON over Unix socket (~/.config/herdr/herdr.sock)
    │
HerdrClient.request()  → connect-per-call (herdr closes socket after one req/resp)
HerdrClient.events()   → ONE long-lived connection, reconnects with backoff
    │
    ▼
StateStore (@MainActor @Observable)  → hydrate(snapshot) then apply(event)
    │
    ├─→ ScreenAdapterRegistry  (exact agent ID → PendingInteraction)
    │     ├─ ClaudeScreenAdapter
    │     ├─ CodexScreenAdapter
    │     └─ GenericScreenAdapter (safe raw fallback)
    ├─→ InteractionDisplayModel + InteractionResponsePlanner (pure; no transport)
    ├─→ ScreenInteractionProvider → InteractionResponder (fresh-read safety boundary)
    ├─→ PromptClassifier  (temporary ClassifiedPrompt compatibility facade)
    └─→ Actions           (approve/deny/answer/reply/jump → send_keys/send_text/focus + Ghostty raise)
    │
NotchApp UI (NSPanel + SwiftUI)  /  notchctl CLI
```

## Protocol facts that shaped the code (verified live against herdr 0.7.4 / protocol 16)

- **One request per connection.** The server closes the socket after a single
  request/response. `HerdrClient.request` connects per call. Only `events()`
  keeps a connection open. Do NOT build a persistent multiplexed request channel.
- **`pane.agent_status_changed` is per-pane** — its subscription requires a
  `pane_id`. There is no global status firehose. `StateStore.currentSubscriptions()`
  emits one entry per pane + the global `pane.agent_detected`/`created`/`exited`,
  and is re-derived on every (re)connect. Do *not* add `pane.output_matched` to
  that set — herdr requires it per-pane WITH a `source` field, and one bad entry
  makes herdr reject the *entire* subscribe batch (`invalid_request`) so no events flow.
- **Status is driven by POLLING, not events.** On the live build,
  `pane_agent_status_changed` events are sparse/absent (a pane can sit `blocked`
  and never emit one), but `session.snapshot` always has correct `agent_status`.
  So `NotchViewModel` polls the snapshot every ~1.5s and calls
  `StateStore.reconcile(_:)` (the primary status path); the event stream is only an
  accelerator + new-pane detector. If you ever see the UI "frozen," suspect the
  event assumption — verify with `notchctl list` (pure snapshot path).
- **herdr replays `pane_created` for long-closed panes on every subscribe.** An
  unfamiliar `pane_id` in an event does not mean a new pane exists — confirm against
  a fresh snapshot before resubscribing, or it thrashes.
- **`pane_created`/`pane_focused` nest the id at `data.pane.pane_id`**;
  `pane_agent_status_changed` uses `data.pane_id`. `EventEnvelope.paneID` checks both.
- **Envelopes are nested by result type:** `session.snapshot`→`result.snapshot...`,
  `pane.read`→`result.read.text`, `pane.focus`/`pane.get`→`result.pane`. Events
  arrive as `{event:"<snake_name>", data:{…}}`. Models decode the nested shapes.
- **Snapshot may repeat panes** — `Snapshot.uniquePanes` dedups by `pane_id`.
- **`done` is rollup-only.** `PaneAgentState` (per-pane authored) has no `done`;
  the store *derives* done (a working-idle pane the user hasn't viewed). See
  `StateStore.derivedStatus`.
- **Raw keys only.** `send_keys`/`send_input` reject `prefix+` chords and invalid
  keys before writing; `Actions` surfaces that as `ActionError.keysRejected` and
  never retries blindly. **Never auto-answer** — every action is user-initiated.

## Conventions

- **Fixtures are the test corpus.** Real captures live canonically in
  `Tests/HerdrClientTests/Fixtures/` and are bundled via `.copy` (which preserves
  the directory, so resolve with `Bundle.module.resourceURL`, not `forResource:`).
  Never hand-write a "live" prompt fixture; capture from a real agent with
  `notchctl capture` and keep its provenance metadata beside the fixture.
- **Decode-tolerant models.** Unknown JSON fields are ignored; unknown enum values
  map to `.unknown` rather than throwing. A decode failure on unknown input is a bug.
- Swift 6 strict concurrency: UI + `StateStore` are `@MainActor`. A CLI/loop that
  touches the store should live inside one `@MainActor` container (see `notchctl`).

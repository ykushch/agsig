# NotchAgent

A native macOS notch control surface for AI coding agents running under
[herdr](https://herdr.dev), driven from Ghostty. **Monitor, approve/deny, answer,
and jump to** your agents from the MacBook notch — without hunting through
terminal panes for the one that's blocked.

herdr is the state authority (it normalizes 15+ agents into one status model and
a JSON socket API); this app is a **socket client + notch `NSPanel` UI**. Full
rationale in [`../notch-agent-control-plane.md`](../notch-agent-control-plane.md);
milestones in [`../execution-plan.md`](../execution-plan.md).

## Requirements

- macOS 14+ on Apple Silicon, Swift 6.2 toolchain (Xcode 16+).
- [herdr](https://herdr.dev) installed and running; Ghostty attached to it.
- No third-party dependencies (Foundation/AppKit/SwiftUI + POSIX sockets).

## Build

```bash
swift build            # all targets
swift test             # full test suite (swift-testing)
```

## `notchctl` — headless CLI harness

Dogfoods the whole core (client + store + classifier + actions) before/without
the UI. Thin wrapper: all logic lives in the `HerdrClient` library.

```bash
swift run notchctl list                      # list all agents + rollup status (F1)
swift run notchctl watch                     # stream status changes; classify blocks (F1/F2/F4)
swift run notchctl read  <pane>              # show the classified prompt for a pane (F4)
swift run notchctl resolve <pane> <choice>   # choice = approve | deny | <option number> (F3/F4)
swift run notchctl reply <pane> <text...>    # free-text reply, submits with enter (F4/F9)
swift run notchctl jump  <pane>              # focus the pane + raise Ghostty (F5)
```

Global flags: `--json` (machine-readable output), `--sock <path>` (explicit
socket path; otherwise resolved from `HERDR_SOCKET_PATH` → `HERDR_SESSION` →
`~/.config/herdr/herdr.sock`).

Example:

```bash
$ swift run notchctl list
● w3:p1           working  claude   /Users/you/project *
○ w1:p1           idle     claude   /Users/you/other
```

`resolve`/`reply` read the pane's current prompt via `pane.read --source detection`,
classify it, and send **raw keys only** (herdr rejects `prefix+` chords). Unknown
prompt shapes fall back to a raw view — the tool never fabricates a keystroke.

## `NotchApp` — the notch UI

```bash
swift run NotchApp
```

Runs as an **accessory app** (no Dock icon, never steals focus). A non-activating
always-on-top `NSPanel` sits around the notch: a collapsed pill (agent count +
worst-state color) that auto-expands into a card when an agent goes `blocked`.
See [`Sources/NotchApp/README.md`](Sources/NotchApp/README.md) for the manual
test checklist.

## Layout

- `Sources/HerdrClient/` — the M1 core (socket client, models, state store, prompt
  classifier, action layer). See [`CLAUDE.md`](CLAUDE.md) for architecture + the
  protocol facts that shaped it.
- `Sources/notchctl/` — the CLI harness.
- `Sources/NotchApp/` — the notch UI (M2).
- `Tests/HerdrClientTests/` — swift-testing suite over recorded fixtures.

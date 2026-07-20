# NotchAgent

A native macOS notch control surface for AI coding agents running under
[herdr](https://herdr.dev), driven from Ghostty. **Monitor, approve/deny, answer,
and jump to** your agents from the MacBook notch — without hunting through
terminal panes for the one that's blocked.

herdr is the state authority (it normalizes 15+ agents into one status model and
a JSON socket API); this app is a **socket client + notch `NSPanel` UI**. The core
hydrates from snapshots, reconciles agent state continuously, and treats events as
an accelerator. The UI stays thin and every response remains explicitly user-driven.

## Requirements

- macOS 14+ on Apple Silicon, Swift 6.2 toolchain (Xcode 16+).
- **[herdr](https://herdr.dev) must be installed and running**, with Ghostty
  attached to it, before NotchAgent can discover or control agents.
- No third-party dependencies (Foundation/AppKit/SwiftUI + POSIX sockets).

## Install

With Homebrew:

```bash
brew install --cask ykushch/tap/notchagent
```

If macOS quarantine blocks the ad-hoc-signed app, reinstall with
`brew install --cask --no-quarantine ykushch/tap/notchagent`.

Alternatively, download `NotchApp-<version>.zip` from GitHub Releases, extract
it, and move `NotchApp.app` to `/Applications`. Because release bundles are
ad-hoc signed rather than notarized, first launch requires right-clicking the app
and choosing **Open**, or removing quarantine explicitly:

```bash
xattr -dr com.apple.quarantine /Applications/NotchApp.app
```

To build an app bundle from source:

```bash
./bundle.sh && open build/NotchApp.app
```

On first launch, grant **Notch Agent** access in **System Settings → Privacy &
Security → Accessibility**. This permission is required for global shortcuts and
agent actions; if a stale denied entry exists, remove it with the − button first.

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
swift run notchctl --json read <pane>         # normalized evidence + proposed response plans
swift run notchctl --json inspect <fixture>   # verify and inspect an offline .fixture directory
swift run notchctl --json dry-run <pane> option 2 # re-read + plan; never send input
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

### Interaction diagnostics

`read --json` reports the normalized provider and screen adapter, stable
fingerprint, interaction kind/content, choices/steps, presentation state,
capabilities, confidence, pane revision, and every proposed response plan or
explicit refusal. Output keys are sorted so identical evidence produces
byte-identical JSON. Raw terminal bytes are deliberately excluded; use
`capture` for raw evidence and `inspect` for normalized diagnostics.

`inspect <path>` verifies and parses a content-addressed `.fixture` directory
without connecting to herdr. A standalone detection file is also supported with
`--agent ID` and optional `--visible FILE`, `--pane ID`, and `--revision N`.

`dry-run <pane> <intent>` reads the interaction once, immediately re-reads it,
compares stable fingerprints, and plans from the fresh presentation. Its core
boundary has no action/transport sender and cannot write input. Supported intents
are `option N`, `check N`, `uncheck N`, `type TEXT`, `text TEXT`,
`option-text N TEXT`, `add-notes`, `clear-notes`, `previous`, `next`, `step N`,
`submit`, `approve`, `deny`, and `cancel`. Pass
`--expected-fingerprint HEX` to audit a previously observed identity.

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

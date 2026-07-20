# Provider data-source decisions

This document is the gate for provider-derived UI. NotchAgent must not label
terminal heuristics or unrelated aggregates as quota, model, or permission
authority.

## OpenCode native provider (accepted)

OpenCode's supported local server is the authoritative source. It exposes an
OpenAPI schema, session status/messages/diffs, pending permissions, permission
replies, providers/models, and server-sent events. See the official
[server documentation](https://opencode.ai/docs/server/) and upstream
[`PermissionNext.Request`/`Reply`](https://github.com/anomalyco/opencode/blob/dev/packages/opencode/src/permission/next.ts).

herdr pane metadata supplies discovery without process scraping:

- `opencode_url`: loopback HTTP origin only; credentials and remote hosts are
  rejected.
- `opencode_session`: exact native session ID.
- `opencode_model`: optional model ID reported by the same integration.

For a fixed-port OpenCode TUI, an integration reporter can publish the binding
without credentials:

```bash
herdr pane report-metadata PANE_ID \
  --source opencode-native --agent opencode \
  --token opencode_url=http://127.0.0.1:4096 \
  --token opencode_session=SESSION_ID \
  --token opencode_model=PROVIDER/MODEL
```

`opencode session list --format json` provides native session IDs. Reporters
must refresh or clear tokens when a pane changes session; NotchAgent replaces
its descriptor registry from every reconciled herdr snapshot.

The native provider reads pending permissions from `GET /permission` and the
latest non-synthetic user text from `GET /session/{id}/message?limit=100`. The
message lookup supplies display-only `You: …` context and is best-effort, so it
cannot hide or invalidate a permission prompt. Responses revalidate the native
request ID plus normalized fingerprint immediately before posting `once`,
`always`, or `reject`. The provider supports both the current
`POST /permission/{requestID}/reply` contract and OpenCode 1.0's
`POST /session/{sessionID}/permissions/{permissionID}` contract, falling back to
the latter only when the current route returns 404. Screen parsing remains the
fallback for panes without these tokens.

## Claude 5h/7d quota meters (deferred)

Claude Code's local `stats-cache.json` contains aggregate activity and model
token totals. Those values are not subscription-window quota utilization and
must not be presented as 5-hour or 7-day limits. An undocumented OAuth endpoint
is also not an acceptable production contract or credential-handling basis.

Implementation remains deferred until Anthropic documents a local or remote
quota source with window boundaries, reset timestamps, authentication scope,
and rate-limit behavior. At that point it should land behind a separate
`UsageWindowProviding` protocol and never block the herdr state pipeline.

## Codex usage

Deferred for the same reason: model identity or quota must come from a native,
documented provider or explicit herdr metadata, never terminal scraping.

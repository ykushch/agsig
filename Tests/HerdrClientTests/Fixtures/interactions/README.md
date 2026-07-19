# Live interaction fixtures

Each `*.fixture` directory is a content-addressed artifact extracted from a
real `notchctl capture`. It contains:

- `detection.txt`: active herdr detection bytes;
- `visible.ansi`: the matching ANSI-visible bytes;
- `metadata.json`: raw-capture provenance and hashes, deterministic extraction
  region, sanitization mode, observed presentation state, and expected response
  plans.

## Capture and extraction

Capture raw evidence outside the repository first:

```bash
swift run notchctl capture w1:p2 --output /private/tmp/notchagent-captures
```

Prepare an annotation JSON matching `PaneFixtureAnnotations`, then extract the
last active screen region:

```bash
swift run notchctl extract \
  /private/tmp/notchagent-captures/w1_p2.capture \
  --annotations /private/tmp/screen.annotations.json \
  --output Tests/HerdrClientTests/Fixtures/interactions \
  --from-marker 'Question 1/3' \
  --through-marker 'esc to interrupt'
```

Extraction preserves bytes; marker isolation only selects a contiguous range.
If personal data must be redacted, prepare explicit replacement files and pass
`--detection-file` and `--visible-file`. The resulting metadata records
`explicit_replacement`, retains raw-source hashes, and hashes the sanitized
fixture separately. Never silently edit a fixture after extraction.

`PaneFixtureExtractor.verifyFixture` validates every file hash, the canonical
artifact digest, and the content-addressed directory suffix. The test suite
verifies the complete committed corpus.

## Corpus evidence (herdr 0.7.4, protocol 16)

- Exact agent identifier: `codex`.
- Question, notes, review, final-submit, and command-approval screens were all
  reported `blocked` before and after capture.
- Cursor movement, question navigation, and resolution changed pane revision.
- Final submission and denial resolved to herdr's per-pane `done` state.
- A direct request for a multi-select checkbox question still rendered the
  single-select cursor mechanism. No checkbox semantics are inferred for this
  observed Codex build.
- The original synthetic approval was denied with `esc`; the requested file was
  verified absent afterward.
- Codex CLI 0.144.5 approval shortcuts were exercised in an isolated temporary
  workspace: `y` ran the command once, while `p` persisted the displayed exact
  prefix and allowed the identical command to run a second time without another
  blocked prompt. The committed resolved fixtures retain both terminal outcomes.

The sibling `claude-interactions/` corpus uses the same verified bundle format.
Its edit-approval fixture was captured from a disposable Claude Code session in
manual permission mode; the proposed patch was not accepted after capture.

# Prompt: streaming transcription (Phase 6, remainder)

Use this prompt against the `all-ears` repo, `daemon/` Swift package. Per
`docs/roadmap.md`, Phase 6 is "Streaming + browser ingestion" — the browser-
ingestion half **already landed early** (`16c4bbb`, live-verified per journal
`#32`–`#39`: loopback WebSocket, `browser:<label>` sources, real audio on
disk). This prompt is the remainder: `transcribe --follow` and the live-feed
`segment` publishing it depends on. Confirmed unbuilt: `Transcribe.swift` has
no `--follow` flag; `ParakeetTranscriber` conforms to `Transcriber` only, not
`StreamingTranscriber`; `EarsCore` has no delta-contract/batcher type; and
`ControlRequest`'s fourteen cases have no way for an external process to push
a `segment` event onto the live feed — only `CaptureActor`/`SessionRegistry`
call `EventBus.publish` today, both from inside `earsd` itself.

## Task

Implement `transcribe --follow <source>`: attach to a live source, decode
incrementally with a real `StreamingTranscriber`, emit an append-only delta
stream to stdout and the session transcript file, and publish finalised
segments to the daemon's live feed for other subscribers — batch and
streaming producing the *same* on-disk transcript format.

## Context (read first)

- `docs/specs/transcribe.md` §"Streaming mode (`--follow`)" and its
  §"Append-only delta contract" subsection — the authoritative behavioural
  spec. Load-bearing requirements, verbatim from there:
  - Emits finalised segments to **stdout** (one per line, `--json` optional),
    **appends to the session transcript file** (the same file batch mode
    would produce), and **publishes `segment` events to the daemon's live
    feed**. "The socket is notification only; the durable transcript is the
    on-disk file" — a subscriber that connects late gets no replay.
  - Must **not** fake streaming by re-transcribing overlapping windows and
    de-duplicating — "wastes compute" and is a named anti-pattern.
  - The delta contract, safe for a **no-backspace sink**: output is
    append-only, the cursor never moves backward; **hold back a trailing
    incomplete unit** (trailing U+FFFD / partial token) until the next step
    confirms it; a **fixed-cadence batcher** decouples chunk arrival from
    model step size; **two-pass finalization** — cheap low-latency partials,
    then one max-look-ahead re-decode before committing to disk (partials
    may change; committed text does not).
  - "This delta logic is pure and lives in `EarsCore`, unit-tested with
    tier-0 tests" — do not build the batcher/hold-back logic inside
    `transcribe`'s executable target where it can't be tier-0 tested.
- `docs/architecture.md` §"Streaming" — the one-paragraph system view:
  `transcribe --follow` "reads newly-written chunks as they land, emits
  finalised segments to stdout, appends to the session transcript file, and
  publishes segments to the control socket's live feed."
- `daemon/Sources/EarsCore/Protocols/StreamingTranscriber.swift` +
  `Models/DecoderState.swift` — the seam: `step(_ frames: AudioBuffer, state:
  inout DecoderState) throws -> [Segment]`. `DecoderState`'s doc comment
  flags itself as "provisional... the real token/hidden-decoder state is
  added by the FluidAudio shim in a later phase" — that later phase is this
  one. `ParakeetTranscriber` (`EarsTranscribeKit/ParakeetTranscriber.swift`)
  needs a real `StreamingTranscriber` conformance backed by FluidAudio's TDT
  streaming decoder; `docs/specs/model-interface.md` already names the
  ANE-serialization (`ANEInferenceGate`) and trailing-silence-pad
  requirements this shares with the batch path — reuse those, don't
  re-solve them.
- `docs/specs/capture-daemon.md` §"Live feed (pub/sub)" — the wire shape:
  `{"ev":"segment","session":"...","speaker":"You","start":604.1,"end":611.9,
  "text":"..."}`, and: **"`segment` events originate from a `transcribe
  --follow` process that publishes back to the daemon, letting many
  consumers watch one live transcript."** This is the concrete gap: publish
  *back to* the daemon, from a separate `transcribe` process, over the
  control socket — not something already wired.
- `daemon/Sources/EarsCore/Socket/ControlRequest.swift` — the 14-case
  request enum (`status` … `flush`); `EarsCore/Socket/EarsEvent.swift`
  already has `.segment(session:speaker:start:end:text:)` fully defined and
  wire-coded — **only the publish-in direction is missing.** Add a new
  `ControlRequest` case (e.g. `segmentPublish`) carrying the same fields as
  `EarsEvent.segment`, decoded/encoded the same way every other case in this
  file is (follow the existing `CodingKeys`/`Tag` pattern exactly — don't
  introduce a second enum style). Route it in `ControlServer` straight to
  `EventBus.publish(.segment(...))` — no persistence, matching every other
  live-feed event's drop-when-unattached semantics
  (`EarsDaemonKit/EventBus.swift`'s doc comment).
- `daemon/Sources/EarsIPC/ControlSocketClient.swift` — the existing
  request/response + subscribe client `transcribe --follow` should connect
  with to send the new publish command. Read its "one outstanding request
  per connection" / subscribe-is-terminal doc comment carefully: a single
  connection **cannot** both `subscribe` and send `segmentPublish` requests
  (subscribe permanently claims the read side). `transcribe --follow` needs
  its own connection to *publish*, separate from anything that might
  `subscribe` to watch — don't try to reuse one client instance for both.
- `daemon/Sources/EarsDaemonKit/EarsDaemon.swift`'s `openIngestSource`
  doc comment — an explicitly flagged, still-open gap directly relevant to
  this phase's UC-4 exit bar: `SessionRegistry.knownSourceIDs` and
  `PowerObserver` were each handed a **snapshot** of `captureActors` at
  `start()`, so **a session opened before a `browser:<label>` source's first
  `ingest.open` can't name it**, and the power observer won't pause/resume
  it on sleep/wake. Only `ControlServer`'s copy stays live (via
  `registerDynamicSource`). Fix the `knownSourceIDs` half here — a live
  Meet/Zoom call session needs to be able to reference a browser participant
  source that joined after the session (or even the daemon) started; the
  `PowerObserver` half can stay a documented follow-up if it's out of this
  task's critical path, but say so explicitly rather than silently leaving
  both unfixed.
- `daemon/Sources/transcribe/TranscribePipeline.swift` and `Transcribe.swift`
  — the batch pipeline and CLI to extend, not replace. `--follow` is a
  genuinely different mode (attach-and-tail vs. resolve-a-range-and-exit),
  so it likely wants its own `TranscribeFollowPipeline` (or similarly named)
  alongside `TranscribePipeline`, sharing `SegmentedAudioReader`/
  `TranscriptAssembly`/`AtomicFileIO` rather than duplicating them.

## Requirements

### 1. Delta contract (`EarsCore`, pure, tier-0)

- A type (e.g. `StreamingDelta`) implementing: monotonic append-only cursor;
  trailing-incomplete-unit hold-back; a fixed-cadence batcher decoupling
  input cadence from model step size. Model this on `docs/specs/
  transcribe.md`'s description directly — there is no existing Swift
  signature to match, so the shape is this task's to design, the same way
  `StreamingTranscriber`'s doc comment already flags `DecoderState` as
  provisional pending this work.
- Two-pass finalization: partials are mutable and re-emittable; once a
  segment is committed (written to the transcript file / published as a
  `segment` event) it is never retracted or edited.
- Tier-0 unit tests only — no daemon, no model, no device, per
  `docs/engineering-practices.md`'s layered test strategy.

### 2. `ParakeetTranscriber: StreamingTranscriber`

- Real `step(_:state:)` backed by FluidAudio's TDT streaming decoder,
  threading `DecoderState` explicitly per-call (caller owns continuity, so
  one transcriber instance can serve multiple concurrent `--follow` runs
  without cross-contaminating state).
- Reuse `ANEInferenceGate` (already built) for the same macOS 14 SIGBUS
  serialization the batch path requires — streaming inference is not exempt.
- `ModelInfo.supportsStreaming = true` once this lands, so any future
  capability check (e.g. Phase 5's diarizer streaming pass) can rely on it.

### 3. `transcribe --follow <source>`

- New CLI flag (`--follow`, taking a source id; `--json` for JSON segment
  lines per the spec's CLI section) and pipeline: tail `index.jsonl` for
  newly-written `chunk`/`vad` events (don't poll the whole file repeatedly —
  track a read offset), decode incrementally through the `StreamingDelta` +
  `StreamingTranscriber` pair as chunks land.
- Emit each finalised segment to stdout (line-buffered, flushed per segment
  so a piped consumer sees it promptly) and append it to the session's
  transcript file — same Markdown/frontmatter renderer batch mode uses
  (`TranscriptRenderer`/`TranscriptAssembly`), so the file is complete and
  correctly formed when the session closes, not a separate format needing
  reconciliation.
- Publish each finalised segment over the control socket via the new
  `segmentPublish` request (requirement below) — best-effort: per the
  "notification only" rule, a publish failure (daemon down, socket
  unreachable) must **not** abort the run or drop the on-disk write; log and
  continue. Disk is the durable copy.
- Exits cleanly on the source's session closing or on signal, flushing any
  held-back partial as a final commit (or discarding it if genuinely
  incomplete — decide and document which, matching this codebase's practice
  of resolving such ambiguity explicitly).

### 4. `segmentPublish` control-socket command

- New `ControlRequest` case, wire-coded exactly like the other thirteen (see
  `ControlRequest.swift`'s `CodingKeys`/`Tag` pattern). Carries the same
  fields as `EarsEvent.segment`.
- `ControlServer` routes it directly to `EventBus.publish`, no session/
  source validation beyond what `EarsEvent.segment`'s wire shape already
  implies — this is a notification pass-through, not a new source of truth.
- Update `docs/specs/capture-daemon.md`'s control-socket command table (the
  "fourteen commands" become fifteen) and the `ControlRequest` type doc
  comment's example block.

### 5. Dynamic browser-source session visibility

- Fix `EarsDaemon`'s `knownSourceIDs` snapshot gap (see Context above) so a
  session opened after daemon start can validate and reference a
  `browser:<label>` source created by a later `ingest.open`. Document the
  `PowerObserver` half's status either way rather than leaving it silently
  ambiguous.

## Tests

- Tier 0: `StreamingDelta`'s hold-back/monotonic-cursor/batcher logic against
  synthetic partial-token sequences — including the specific "trailing
  U+FFFD" and "partial token completed by the next step" cases named in the
  spec.
- Tier 1: `--follow` against a fixture ring buffer that grows during the
  test (chunks appended mid-run, no real daemon) — asserts stdout lines are
  append-only/never-retracted and the transcript file matches what batch
  `transcribe` would produce over the same final range.
- `segmentPublish` round-trips through `ControlRequest`'s `Codable`
  conformance and reaches a subscribed `ControlSocketClient` via `EventBus`
  — a real-loopback-socket integration test, mirroring the existing
  ingest-WebSocket integration tests' shape.
- Regression test for the dynamic-source session gap: a session opened,
  then a `browser:<label>` source's first `ingest.open` happens, then that
  session can validly reference the label (today this throws
  `unknownSource`).

## Out of scope

- Diarization's live/streaming pass — Phase 5 explicitly defers this to
  "once `--follow` exists" (i.e. now unblocked, but wiring it in is Phase
  5's follow-up task, not this one).
- Any change to the already-landed browser-ingestion WebSocket path
  (`IngestWebSocketServer`, `PushCaptureBackend`) — done and live-verified;
  this prompt only adds the transcription-side consumer of that audio.
- CATap system/per-app audio (Phase 4) — `--follow` works against whatever
  source is named; it doesn't need Phase 4 to land first, though a live
  `app:<bundle-id>` source obviously can't stream until Phase 4 makes it
  capture anything.
- The `PowerObserver` half of the dynamic-source gap, if you judge it
  genuinely separable — but say so explicitly per requirement 5, don't
  silently drop it.

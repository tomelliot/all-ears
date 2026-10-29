# Spec: control protocol v2

**Status: implemented.** This spec defines the control contract between `earsd` and every
frontend, and is the implemented wire — it supersedes the v1 flat-`cmd` protocol
[`capture-daemon.md`](capture-daemon.md) used to describe (that doc now defers here for
everything but ingest). The golden wire fixtures both codecs are tested against live in
`shared/protocol-fixtures/control-v2.json`. The ingest WebSocket (`/ingest`, binary PCM) is
**out of scope** and unchanged.

**No backwards compatibility.** There is no external v1 usage: every client lives in this repo
and moves in lockstep. v2 **replaces** the v1 wire outright — the flat-`cmd` envelope, FIFO
response matching, and the v1 lifecycle verbs are deleted, not deprecated, and there is no
dual-dialect transition period. Implementation optimizes for speed, clarity, and long-term
maintainability, never for transition safety.

## One job

One transport-agnostic contract that lets any frontend — the `ears` CLI, the browser extension,
a future menu-bar app, the extension popup, several of them at once — drive and observe the
daemon: sources, capture, **sessions** (start/end, pause/resume-as-marks, attendees, title),
and the live feed. Identical frames over the Unix socket and the loopback control
WebSocket; privilege differs by transport, not by dialect.

## Why v2 (design rationale)

The v1 contract grew organically and had four structural weaknesses:

1. **No correlation IDs.** Responses were matched FIFO per connection: pipelining was unsafe, a
   slow command head-of-line-blocked a fast one, and a disconnect stranded every pending request.
2. **No state sync.** v1's `subscribe` was terminal and had no snapshot or replay — a client had
   to `list` then `subscribe` with a race window between them.
3. **No handshake.** No protocol version, no capability discovery, string-only errors.
4. **The lifecycle state machine lived in the client.** The extension held the roster it never
   sent and kept its call-tracking state in an MV3 service worker the browser could evict at
   any time.

v2 fixes these with: an id-correlated envelope + `hello` handshake; snapshot-on-subscribe with
revision-tagged events; and a daemon-owned **Session** entity.

Alternatives considered and rejected: a Kubernetes-style declarative state document (wrong shape
for a mostly imperative domain — `flush` and "start *now*" don't fit patches, and a reconciler
violates "the daemon only records, never decides"); a full event-sourced journal with client
cursors (every client must implement a matching reducer, and frontends want current state, not
history — its one good idea, a durable per-session event log *on disk*, is kept); file-based
metadata mutation (the extension cannot touch the filesystem). An incremental "just add
lifecycle verbs to the v1 wire" option was rejected because the multi-frontend requirement is
exactly what the v1 subscribe race and FIFO matching break on, and with no external users there
was nothing the v1 wire's survival would buy.

## Wire envelope

JSON, one message per line (Unix socket, NDJSON) or per text frame (WebSocket). Three shapes:

```jsonc
// request  (client → daemon). `id` is client-chosen, unique per connection.
{"id": 7, "method": "session.pause", "params": {"session": "0d5e…"}}

// response (daemon → client). Exactly one per request; MAY arrive out of order.
{"id": 7, "result": {"state": "paused", "rev": 42}}
{"id": 7, "error": {"code": "session_not_found", "message": "no active session 0d5e…"}}

// notification (daemon → subscribers). No `id`; carries the state revision.
{"event": "session", "params": {"session": {…}}, "rev": 43}
```

- `id` is any JSON string or number; the daemon echoes it verbatim. Correlation makes
  out-of-order completion legal — clients keep a pending map, not a FIFO queue.
- `error.code` is a stable machine-readable identifier (see [Errors](#errors)); `message` is
  human prose and never load-bearing.
- Binary frames are rejected on both control transports (PCM belongs to `/ingest` only).

### Handshake

`hello` MUST be the first request on every connection; anything else first gets
`error.code = "hello_required"`.

```jsonc
// -->
{"id": 0, "method": "hello", "params": {"protocol": 2, "client": "browser-extension/0.4"}}
// <--
{"id": 0, "result": {
  "protocol": 2,
  "daemon": "earsd 0.9.0",
  "boot_id": "b3f1…",                    // fresh per daemon start; revs are scoped to it
  "capabilities": ["observe", "sessions", "publish", "sources", "admin"]
}}
```

- `protocol` is a single integer. A server that cannot speak the requested version answers
  `error.code = "unsupported_protocol"` with the versions it does speak in `message`.
- `capabilities` is the set this *connection* may use (see
  [Transports & privilege](#transports--privilege)); frontends grey out what's absent instead of
  discovering `not_permitted` errors.
- `boot_id` tells a reconnecting client whether the daemon restarted (revision counters and
  in-memory state are not comparable across boots).

## Entities

### Session

The daemon-owned lifecycle entity. Owns transcription marks, roster, and title; capture is
scoped to its lifetime. Persisted as `sessions/<uuid>/session.toml` (schema 3, +
`events.jsonl` — see [Disk artifacts](#disk-artifacts)).

```jsonc
{
  "id": "0d5e…",                          // daemon-assigned UUID
  "identity": {"platform": "meet", "external_id": "abc-defg-hij"},  // optional; absent for manual sessions
  "title": "Weekly sync",                 // renameable; defaults from identity or start time
  "state": "active",                      // active | paused | ended
  "started": "2026-07-19T10:00:00Z",
  "ended": null,
  "intervals": [                          // transcription marks over the recording
    {"start": "2026-07-19T10:00:00Z", "end": "2026-07-19T10:12:30Z"},
    {"start": "2026-07-19T10:20:05Z", "end": null}   // null end = currently marked
  ],
  "attendees": [
    {"id": "spaces/x/devices/y", "display_name": "Jane Doe",
     "joined": "2026-07-19T10:00:12Z", "left": null,
     "source": "browser:meet:jane-a1b2",  // optional mapping to a SourceID
     "origin": "platform"}                // platform | synthetic; absent = unknown
  ],
  "sources": ["mic", "browser:meet:jane-a1b2"],
  "trigger": "browser-extension",         // manual | browser-extension
  "transcript_completed": null,           // set when the auto-transcribe exits 0
  "pipeline_issues": [                    // omitted when empty; see capture-daemon.md
    {"stage": "summarize", "kind": "failed", "exit_class": "retryable-upstream",
     "message": "LLM backend call timed out"}
  ],
  "rev": 43                               // last revision that touched this session
}
```

Semantics:

- **Capture is session-scoped.** `session.start` starts capture of the session's declared local
  sources (mic, system, app); everything they record lands under
  `sessions/<uuid>/sources/`. `session.end` stops capture and tears the engines down.
  `browser:*` sources are driven by their ingest streams instead — the daemon links them into
  the session but does not run capture engines for them.
- **Intervals are marks, never capture control.** Pausing a session closes the open interval;
  resuming opens a new one. The audio store, capture engines, and ingest streams are untouched —
  the marks are metadata over the recording. (Source-level `capture.pause` still exists,
  unchanged, for actually stopping a source.)
- **`session.start` is idempotent on `identity`** (`platform` + `external_id`, the platform's
  own meeting id). Re-declaring an active session returns its current state, merging any
  newly-named sources. This is the recovery path for both service-worker eviction and daemon
  restart: a recovered client just re-declares and converges.
- **One active session at a time.** A `session.start` for a *different* identity (or a manual
  start) supersedes any session still live: the old session runs its full end pipeline
  (`reason = "superseded"`) before the new one is created, so exactly one session directory is
  ever a legal capture target.
- **Manual sessions are first-class.** `session.start` without `identity` creates a session from
  any frontend — `ears session start --title standup --source mic` gives CLI recordings the
  same naming, pause-as-marks, and roster powers as browser calls. Manual sessions are never
  auto-ended (see [Orphaned sessions](#orphaned-sessions)).
- **Attendees are a roster with join/leave times**, upserted by whoever knows them (the
  extension's DOM layer today). `source` links an attendee to their per-participant audio
  source, which downstream feeds the transcript's speaker labels. `origin` records where
  the attendee's `id` was minted: `platform` (the platform's own id — a Meet device path,
  a Zoom node id) or `synthetic` (a capture-client stand-in like `speaker-<n>` that names
  a track, not a person). Absent means unknown (old clients, old files); an upsert that
  omits it leaves the stored value untouched. Reconciliation counts only platform-origin
  rows as named remote participants.
- **On `session.end`,** the daemon closes the open interval, finalizes the session record
  (`session.toml` holds the intervals and roster that transcription reads directly), and stops
  capture. For browser-triggered sessions the daemon then runs the on-end pipeline
  (`transcribe --session <id>`, then `cleanup` and `summarize` over its output — see
  [capture-daemon](capture-daemon.md#session-end-pipeline)); when the transcribe stage exits 0
  the daemon stamps `transcript_completed`, which starts the retention clock
  ([capture-daemon](capture-daemon.md#storage-maintenance-and-retention)).

### Transcription output

The canonical artifact is **one transcript per session**. `transcribe --session <id>` reads
`session.toml`, unions the session's intervals (paused spans are skipped exactly like silence),
and writes a single transcript whose frontmatter carries a `session:` field (the UUID)
alongside the `range:` fields. The session-level union is what the on-end pipeline and
users invoke; raw ranges (`--last`/`--from`/`--to`) remain available and carry a synthesized
`range_run:` identifier instead. `cleanup` and `summarize` run over the transcript file, fed
by the on-end pipeline or by hand ([llm-stages](llm-stages.md)).

### Sources

Sources remain the capture unit with runtime states `capturing|paused|disabled|error`.
Sessions are the only lifecycle entity and the only transcription work unit.

## Methods

Grouped by capability. All carried in the v2 envelope.

| Capability | Method | Params → result |
|---|---|---|
| — | `hello` | see [Handshake](#handshake) |
| `observe` | `status` | → `{uptime_s, sources, sessions}` — daemon + per-source state, active sessions |
| `observe` | `subscribe` | `{events?, sources?}` → **snapshot** (see [State sync](#state-sync)) |
| `sessions` | `session.start` | `{platform?, external_id?, title?, sources?, trigger?}` → full session object. Idempotent on identity; without identity creates a manual session; supersedes any other live session |
| `sessions` | `session.end` | `{session}` → final session object. Closes the open interval, stops capture |
| `sessions` | `session.pause` | `{session}` → session. Closes open interval; no-op success if already paused |
| `sessions` | `session.resume` | `{session}` → session. Opens a new interval; no-op success if active |
| `sessions` | `session.rename` | `{session, title, if_rev?}` → session. `if_rev` mismatch → `conflict` |
| `sessions` | `session.attendee` | `{session, id, display_name?, joined?, left?, source?, origin?, self?}` → session. Upsert |
| `sessions` | `session.list` | `{}` → live + recent sessions (ended history is read from disk, not the socket) |
| `sessions` | `session.get` | `{session}` → session |
| `admin` | `session.retry` | `{session, from, input?}` → session, once the chain stops. Reruns an ended session's on-end chain from `from` (`transcribe`, `cleanup` or `summarize`). `input` is the file the resumed stage reads: the transcript for `cleanup` (default: the session's own `transcript.md`), the cleaned transcript for `summarize` (required). Issues recorded by earlier stages are kept. Not ended, unknown stage, or a stage not in `on_end_stages` → `invalid_request`; a chain already running for the session → `conflict` |
| `publish` | `segment.publish` | `{session, speaker, start, end, text}` → `{}`. Notification-only republish from `transcribe --follow` |
| `publish` | `job.publish` | `{job, kind: "transcribe", session?, state: "started"\|"running"\|"done"\|"failed", detail?}` → `{}`. Notification-only, same pattern as `segment.publish`: pipeline tools report progress, the daemon persists nothing, subscribers get real state instead of guessing |
| `sources` | `sources.list` / `sources.enable` / `sources.disable` | source listing and enable/disable |
| `admin` | `sources.add` / `sources.remove` / `capture.pause` / `capture.resume` / `flush` | runtime source mutation and capture control |

## State sync

`subscribe`'s **result is a snapshot** of live state, tagged with a monotonic revision; every
subsequent **state** notification carries `rev`. This closes v1's list-then-subscribe race with
no replay log, no cursors, and no daemon-side buffering — the daemon keeps only current state
plus one counter.

```jsonc
// -->
{"id": 1, "method": "subscribe", "params": {"events": ["segment", "job"]}}
// <-- snapshot
{"id": 1, "result": {
  "rev": 41,
  "sessions": [ {…active/paused sessions…} ],
  "sources":  [ {"id": "mic", "state": "capturing"}, … ]
}}
// <-- then notifications: state events revision-tagged, telemetry un-revved
{"event": "session", "params": {"session": {…}}, "rev": 42}
{"event": "source",  "params": {"id": "mic", "state": "paused"}, "rev": 43}
{"event": "vad",     "params": {"source": "mic", "state": "speech", "t": "…"}}
{"event": "segment", "params": {"session": "0d5e…", "speaker": "You", "start": 604.1, "end": 611.9, "text": "…"}}
{"event": "job",     "params": {"job": "j3", "kind": "transcribe", "session": "0d5e…", "state": "running"}}
```

Client rule: apply a state notification iff `rev == last_rev + 1`; on a gap, resubscribe (fresh
snapshot). On reconnect: `hello` → compare `boot_id` → `subscribe`. An MV3 service worker can
therefore be fully stateless: everything it needs to render or resume comes back in one snapshot.

- **Two event classes.** *State* events (`session`, `source`) mutate the synced state,
  carry `rev`, and are **always delivered** to every subscriber — they're low-frequency, and
  unconditional delivery is what keeps `rev` contiguous. *Telemetry* events (`vad`, `segment`,
  `job`) are fire-and-forget, carry **no** `rev`, never participate in gap detection, and are the
  kinds `params.events`/`params.sources` filter.
- **Subscribing is not terminal.** With correlation IDs, a subscribed connection may keep
  issuing requests; one connection per frontend suffices.
- Late subscribers get the snapshot, not history. Durable history lives on disk
  (transcripts, `session.toml`, `events.jsonl`) — the socket serves live state only.

## Errors

Stable codes; clients switch on `code`, never on `message`:

`hello_required`, `unsupported_protocol`, `invalid_request`, `unknown_method`, `not_permitted`,
`session_not_found`, `session_ended`, `source_not_found`, `conflict` (failed `if_rev`),
`internal`.

## Transports & privilege

Identical frames on both transports; **privilege tiers by transport**, assigned at connect and
advertised in `hello.result.capabilities`:

| Transport | Capabilities |
|---|---|
| Unix domain socket | `observe`, `sessions`, `publish`, `sources`, `admin` (full) |
| `ws://127.0.0.1:<port>/control` | `observe`, `sessions` |
| `ws://127.0.0.1:<port>/ingest` | none of the above — the ingest contract, unchanged |

- The Unix socket remains the privileged plane (filesystem-permission-gated). The control
  WebSocket keeps loopback-only binding and the fail-closed Origin allowlist, and also
  can't reach source/publish/admin verbs even from an allowed origin — the extension only ever
  needed session verbs plus observation.
- Residual risk: any local process can present an allowed Origin to the WS.
  A user-configured bearer token remains a documented future option; single-local-user remains
  the threat model.

## Disk artifacts

- **`sessions/<uuid>/session.toml` (schema 3):** the fields of the session object above.
  Written atomically on every mutation; reloaded at daemon start (an `active` session with an
  open interval survives a restart). See [data-formats](../data-formats.md#sessions-sessionsuuid).
- **`sessions/<uuid>/events.jsonl` (append-only):** one line per domain event —
  `started`, `interval_opened`, `interval_closed`, `attendee_joined`, `attendee_left`,
  `renamed`, `ended` — the durable timeline (who was present during minutes 10–20, when pauses
  happened, what the session used to be called). Written for disk consumers (`summarize`,
  humans, `jq`), **not** used for protocol sync; mirrors the index idiom.
- Ended sessions are read from disk, daemon-free (`ears session list --all` reads
  `sessions/*/session.toml` directly). The socket's `session.list` covers live + recent only.

### Orphaned sessions

A session can be left `active` with nobody driving it — browser crash, laptop lid closed,
service worker gone for good. Policy, split by session kind:

- **Browser sessions** (any `browser:*` source in play): when the **last ingest stream** tied to
  the session's sources has been closed for `[earsd.sessions] ingest_close_grace_s` (default
  120 s) with no re-open, the daemon closes the open interval and ends the session. The grace
  period is what distinguishes a worker respawn or network blip (streams re-open, nothing
  happens) from a real departure. The `ended` line in `events.jsonl` records
  `reason = "ingest-idle"` (vs `"client"` for an explicit `session.end`).
- **Manual sessions** (no ingest streams to observe): **never auto-ended** — the daemon records,
  it doesn't decide. `session.end` is required; `ears session list` surfaces stale ones.

On daemon restart, `active`/`paused` sessions reload from `session.toml`; at most one is chosen
to resume (the single-active-session invariant), and any others found live on disk are swept
through the normal end pipeline with `reason = "orphaned"` so their audio isn't stranded. A
resumed browser session whose streams don't return starts its grace clock from daemon boot.

## Failure model

- **Service-worker eviction / reconnect mid-call:** reconnect → `hello` → `subscribe`
  snapshot → re-declare via idempotent `session.start` if the DOM says a call is live. Ingest
  streams re-open lazily as PCM arrives (unchanged).
- **Daemon restart mid-call:** session state reloads from `session.toml`; clients detect the
  restart via `boot_id` and re-converge exactly as above. At most the in-flight mutation is lost.
- **Two frontends concurrently:** lifecycle verbs are idempotent and converge; snapshot+`rev`
  keeps every subscriber within one event of truth; `if_rev` makes rename a safe compare-and-set
  instead of silent last-write-wins.

## Verification

- **Golden wire fixtures** shared by the Swift and TypeScript test suites
  (`shared/protocol-fixtures/control-v2.json`): the same JSON frames decoded/encoded by both
  sides, so the two codecs can never drift.
- `browser/dev/stub-server.ts` speaks v2 for extension tests.
- Daemon tests: idempotent `session.start`; pause/resume interval bookkeeping (capture provably
  untouched); restart recovery of an active session; orphan grace timer (streams closed → grace
  elapses → ended with `reason="ingest-idle"`; re-open within grace → still active); snapshot +
  `rev` gap detection with telemetry kinds filtered; per-transport capability enforcement.
- `transcribe` test: `--session` unions intervals (paused span provably absent from output) and
  publishes `job` events through the daemon.
- Extension test: service-worker kill mid-call recovers via `hello` + `subscribe` with no
  duplicated or dropped session.

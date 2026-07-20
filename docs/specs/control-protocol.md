# Spec: control protocol v2

**Status: designed, not yet implemented.** This spec defines the target control contract between
`earsd` and every frontend. When it lands it supersedes the "Control protocol" section of
[`capture-daemon.md`](capture-daemon.md), which describes the v1 wire as currently implemented.
The ingest WebSocket (`/ingest`, binary PCM) is **out of scope** and unchanged.

**No backwards compatibility.** There is no external v1 usage: every client lives in this repo
and moves in lockstep. v2 **replaces** the v1 wire outright — the flat-`cmd` envelope, FIFO
response matching, and `meeting.resolve` are deleted, not deprecated, and there is no
dual-dialect transition period. Implementation optimizes for speed, clarity, and long-term
maintainability, never for transition safety. See [Implementation order](#implementation-order).

## One job

One transport-agnostic contract that lets any frontend — the `ears` CLI, the browser extension,
a future menu-bar app, the extension popup, several of them at once — drive and observe the
daemon: sources, capture, **meetings** (start/end, pause/resume-as-marks, attendees, title),
sessions, and the live feed. Identical frames over the Unix socket and the loopback control
WebSocket; privilege differs by transport, not by dialect.

## Why v2 (design rationale)

The v1 contract grew organically and has four structural weaknesses:

1. **No correlation IDs.** Responses are matched FIFO per connection: pipelining is unsafe, a
   slow command head-of-line-blocks a fast one, and a disconnect strands every pending request.
2. **No state sync.** `subscribe` is terminal, carries only `vad`/`session`/`segment`, and has no
   snapshot or replay — a client must `list` then `subscribe` with a race window between them.
3. **No handshake.** No protocol version, no capability discovery, string-only errors.
4. **The meeting state machine lives in the client.** The extension emulates pause/resume by
   closing and re-opening sessions under a meeting UUID, holds the roster it never sends, and
   keeps all of it in an MV3 service worker the browser can evict at any time.

v2 fixes these with: an id-correlated envelope + `hello` handshake; snapshot-on-subscribe with
revision-tagged events; and a daemon-owned **Meeting** entity layered above sessions.

Alternatives considered and rejected: a Kubernetes-style declarative state document (wrong shape
for a mostly imperative domain — `flush`, `mark --last 30m`, "start *now*" don't fit patches, and
a reconciler violates "the daemon only records, never decides"); a full event-sourced journal
with client cursors (every client must implement a matching reducer, and frontends want current
state, not history — its one good idea, a durable per-meeting event log *on disk*, is kept);
file-based metadata mutation (the extension cannot touch the filesystem). An incremental
"just add meeting verbs to the v1 wire" option was rejected because the multi-frontend
requirement is exactly what the v1 subscribe race and FIFO matching break on, and with no
external users there is nothing the v1 wire's survival would buy.

## Wire envelope

JSON, one message per line (Unix socket, NDJSON) or per text frame (WebSocket). Three shapes:

```jsonc
// request  (client → daemon). `id` is client-chosen, unique per connection.
{"id": 7, "method": "meeting.pause", "params": {"meeting": "0d5e…"}}

// response (daemon → client). Exactly one per request; MAY arrive out of order.
{"id": 7, "result": {"state": "paused", "rev": 42}}
{"id": 7, "error": {"code": "meeting_not_found", "message": "no active meeting 0d5e…"}}

// notification (daemon → subscribers). No `id`; carries the state revision.
{"event": "meeting", "params": {"meeting": {…}}, "rev": 43}
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
  "capabilities": ["observe", "meetings", "sessions", "sources", "admin"]
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

### Meeting

The daemon-owned lifecycle entity — what v1's client-side meeting tracker becomes. Layered
*above* sessions; owning marks, roster, and title. Persisted as
`meetings/<uuid>/meeting.toml` (+ `events.jsonl`, see [Disk artifacts](#disk-artifacts)).

```jsonc
{
  "id": "0d5e…",                          // daemon-assigned UUID
  "identity": {"platform": "meet", "external_id": "abc-defg-hij"},  // optional; absent for manual meetings
  "title": "Weekly sync",                 // renameable; defaults from identity or slug
  "state": "active",                      // active | paused | ended
  "started": "2026-07-19T10:00:00Z",
  "ended": null,
  "intervals": [                          // transcription marks over the ring buffer
    {"start": "2026-07-19T10:00:00Z", "end": "2026-07-19T10:12:30Z"},
    {"start": "2026-07-19T10:20:05Z", "end": null}   // null end = currently marked
  ],
  "attendees": [
    {"id": "spaces/x/devices/y", "display_name": "Jane Doe",
     "joined": "2026-07-19T10:00:12Z", "left": null,
     "source": "browser:meet:jane-a1b2"}  // optional mapping to a SourceID
  ],
  "sources": ["mic", "browser:meet:jane-a1b2"],
  "trigger": "browser-extension",
  "rev": 43                               // last revision that touched this meeting
}
```

Semantics:

- **Intervals are marks, never capture control.** Pausing a meeting closes the open interval;
  resuming opens a new one. The ring buffer, capture engines, and ingest streams are untouched —
  a session/meeting is metadata over the buffer, exactly as v1 sessions are. (Source-level
  `capture.pause` still exists, unchanged, for actually stopping a source.)
- **`meeting.start` is idempotent on `identity`.** Re-declaring an active meeting returns its
  current state. This is the recovery path for both service-worker eviction and daemon restart:
  a recovered client just re-declares and converges.
- **Manual meetings are first-class.** `meeting.start` without `identity` creates a meeting from
  any frontend — `ears meeting start --title "standup" --source mic` gives CLI recordings the
  same naming, pause-as-marks, and roster powers as browser calls. Manual meetings are never
  auto-ended (see [Orphaned meetings](#orphaned-meetings)); `ears meeting ...` subcommands are
  part of v2 scope.
- **Attendees are a roster with join/leave times**, upserted by whoever knows them (the
  extension's DOM layer today). `source` links an attendee to their per-participant audio source,
  which downstream feeds the transcript's speaker-name map (`[speakers]` in
  [data-formats](../data-formats.md#speaker-attribution)).
- **On `meeting.end`,** the daemon closes the open interval, **materializes one closed
  `SessionDescriptor` per interval** (slug = meeting UUID, trigger preserved), and **writes the
  roster into each materialized session's `[speakers]` map** (attendee `source` →
  `display_name`), so real names flow into transcripts with no manual step. Auto-transcription
  triggers fire off meeting end.

### Transcription output

The canonical artifact is **one transcript per meeting**. `transcribe` gains a
`--meeting <id>` mode: it reads `meeting.toml`, unions the meeting's intervals (paused spans are
skipped exactly like silence), and writes a single transcript whose frontmatter carries a
`meeting:` field alongside the existing `session:`/`range:` fields. The per-interval sessions
remain addressable via `transcribe --session` for partial re-runs, but the meeting-level union
is what auto-triggers and users invoke. This is the one deliberate change to the pipeline
contract; `cleanup` and `summarize` are untouched.

### Sessions and sources

Unchanged from v1 ([capture-daemon.md](capture-daemon.md), [data-formats](../data-formats.md)).
Sessions remain the transcription work unit and the CLI's manual marking primitive
(`session.open/close`, `mark`). Sources remain the capture unit with runtime states
`capturing|paused|disabled|error`.

## Methods

Grouped by capability. All carried in the v2 envelope; `params` fields match v1 payloads where
the verb is retained.

| Capability | Method | Params → result |
|---|---|---|
| — | `hello` | see [Handshake](#handshake) |
| `observe` | `status` | → daemon + per-source state, buffer occupancy, active meetings/sessions |
| `observe` | `subscribe` | `{events?, sources?}` → **snapshot** (see [State sync](#state-sync)) |
| `meetings` | `meeting.start` | `{platform?, external_id?, title?}` → full meeting object. Idempotent on identity; without identity creates a manual meeting |
| `meetings` | `meeting.end` | `{meeting}` → final meeting object. Closes open interval, materializes sessions |
| `meetings` | `meeting.pause` | `{meeting}` → meeting. Closes open interval; no-op success if already paused |
| `meetings` | `meeting.resume` | `{meeting}` → meeting. Opens a new interval; no-op success if active |
| `meetings` | `meeting.rename` | `{meeting, title, if_rev?}` → meeting. `if_rev` mismatch → `conflict` |
| `meetings` | `meeting.attendee` | `{meeting, id, display_name?, joined?, left?, source?}` → meeting. Upsert |
| `meetings` | `meeting.list` | `{}` → active + recent meetings (closed history is read from disk, not the socket) |
| `meetings` | `meeting.get` | `{meeting}` → meeting |
| `sessions` | `session.open` / `session.close` / `session.list` / `session.add_source` / `mark` | as v1 |
| `sessions` | `segment.publish` | as v1 (notification-only republish from `transcribe --follow`) |
| `sessions` | `job.publish` | `{job, kind: "transcribe", meeting?, session?, state: "started"\|"running"\|"done"\|"failed", detail?}` → `{}`. Notification-only, same pattern as `segment.publish`: pipeline tools report progress, the daemon persists nothing, subscribers get real state instead of guessing |
| `sources` | `sources.list` / `sources.enable` / `sources.disable` | as v1 |
| `admin` | `sources.add` / `sources.remove` / `capture.pause` / `capture.resume` / `flush` | as v1 |

v1's `meeting.resolve` is subsumed by `meeting.start` and dropped from v2.

## State sync

`subscribe`'s **result is a snapshot** of live state, tagged with a monotonic revision; every
subsequent **state** notification carries `rev`. This closes v1's list-then-subscribe race with
no replay log, no cursors, and no daemon-side buffering — the daemon keeps only current state
plus one counter.

```jsonc
// -->
{"id": 1, "method": "subscribe", "params": {"events": ["meeting", "source", "segment"]}}
// <-- snapshot
{"id": 1, "result": {
  "rev": 41,
  "meetings": [ {…active/paused meetings…} ],
  "sources":  [ {"id": "mic", "state": "capturing"}, … ],
  "sessions": [ {…open sessions…} ]
}}
// <-- then notifications: state events revision-tagged, telemetry un-revved
{"event": "meeting", "params": {"meeting": {…}}, "rev": 42}
{"event": "source",  "params": {"id": "mic", "state": "paused"}, "rev": 43}
{"event": "vad",     "params": {"source": "mic", "state": "speech", "t": "…"}}
{"event": "segment", "params": {"session": "…", "speaker": "You", "start": 604.1, "end": 611.9, "text": "…"}}
{"event": "job",     "params": {"job": "j3", "kind": "transcribe", "meeting": "0d5e…", "state": "running"}}
```

Client rule: apply a state notification iff `rev == last_rev + 1`; on a gap, resubscribe (fresh
snapshot). On reconnect: `hello` → compare `boot_id` → `subscribe`. An MV3 service worker can
therefore be fully stateless: everything it needs to render or resume comes back in one snapshot.

- **Two event classes.** *State* events (`meeting`, `session`, `source`) mutate the synced state,
  carry `rev`, and are **always delivered** to every subscriber — they're low-frequency, and
  unconditional delivery is what keeps `rev` contiguous. *Telemetry* events (`vad`, `segment`,
  `job`) are fire-and-forget, carry **no** `rev`, never participate in gap detection, and are the
  kinds `params.events`/`params.sources` filter.
- **Subscribing is no longer terminal.** With correlation IDs, a subscribed connection may keep
  issuing requests; one connection per frontend suffices.
- Late subscribers get the snapshot, not history. Durable history lives on disk
  (transcripts, `meeting.toml`, `events.jsonl`) — the socket serves live state only.

## Errors

Stable codes; clients switch on `code`, never on `message`:

`hello_required`, `unsupported_protocol`, `invalid_request`, `unknown_method`, `not_permitted`,
`meeting_not_found`, `meeting_ended`, `session_not_found`, `session_already_closed`,
`source_not_found`, `conflict` (failed `if_rev`), `internal`.

## Transports & privilege

Identical frames on both transports; **privilege tiers by transport**, assigned at connect and
advertised in `hello.result.capabilities`:

| Transport | Capabilities |
|---|---|
| Unix domain socket | `observe`, `meetings`, `sessions`, `sources`, `admin` (full) |
| `ws://127.0.0.1:<port>/control` | `observe`, `meetings` |
| `ws://127.0.0.1:<port>/ingest` | none of the above — v1 ingest contract, unchanged |

- The Unix socket remains the privileged plane (filesystem-permission-gated). The control
  WebSocket keeps loopback-only binding and the fail-closed Origin allowlist, and now *also*
  can't reach source/session/admin verbs even from an allowed origin — the extension only ever
  needed meeting verbs plus observation.
- Residual risk (unchanged from v1): any local process can present an allowed Origin to the WS.
  A user-configured bearer token remains a documented future option; single-local-user remains
  the threat model.

## Disk artifacts

- **`meetings/<uuid>/meeting.toml` (schema 2):** the fields of the meeting object above.
  Written atomically on every mutation; reloaded at daemon start (an `active` meeting with an
  open interval survives a restart).
- **`meetings/<uuid>/events.jsonl` (new, append-only):** one line per domain event —
  `started`, `interval_opened`, `interval_closed`, `attendee_joined`, `attendee_left`,
  `renamed`, `ended` — the durable timeline (who was present during minutes 10–20, when pauses
  happened, what the meeting used to be called). Written for disk consumers (`summarize`,
  humans, `jq`), **not** used for protocol sync; mirrors the `index.jsonl` idiom.
- Closed meetings are read from disk, daemon-free (`ears meeting list --all` reads
  `meetings/*/meeting.toml` directly). The socket's `meeting.list` covers live + recent only.

### Orphaned meetings

A meeting can be left `active` with nobody driving it — browser crash, laptop lid closed,
service worker gone for good. Policy, split by meeting kind:

- **Browser meetings** (any `browser:*` source in play): when the **last ingest stream** tied to
  the meeting's sources has been closed for `[meetings] ingest_close_grace_s` (default 120 s)
  with no re-open, the daemon closes the open interval and ends the meeting. The grace period is
  what distinguishes a worker respawn or network blip (streams re-open, nothing happens) from a
  real departure. The `ended` line in `events.jsonl` records `reason = "ingest-idle"` (vs
  `"client"` for an explicit `meeting.end`).
- **Manual meetings** (no ingest streams to observe): **never auto-ended** — the daemon records,
  it doesn't decide. `meeting.end` is required; `ears meeting list` surfaces stale ones.

On daemon restart, `active`/`paused` meetings reload from `meeting.toml` as-is; a reloaded
browser meeting whose streams don't return starts its grace clock from daemon boot.

## Implementation order

No migration, no bridge, no deprecation window — v2 replaces the v1 wire in one change series;
the flat-`cmd` envelope, FIFO matching, and `meeting.resolve` are deleted. Order of work:

1. **Daemon:** the v2 envelope/handshake/errors in `EarsCore/Socket`, `MeetingRegistry` as
   lifecycle owner, snapshot+`rev` in `ControlServer`/`EventBus`, orphan grace timer,
   per-transport capability tiers. v1 handling removed in the same change.
2. **Extension + stub server (same series):** `control-transport.ts` swaps its FIFO array for an
   id→resolver map; `meeting-tracker.ts` shrinks to a signal forwarder (DOM `meeting-started` →
   `meeting.start`, popup pause toggle → `meeting.pause`/`resume` — deleting the session-churn
   emulation and its in-flight race compensation; participant join/leave → `meeting.attendee`);
   `browser/dev/stub-server.ts` speaks v2.
3. **CLI + pipeline:** `ears` ports to v2 and gains
   `ears meeting start|end|pause|resume|rename|list`; `transcribe` gains `--meeting` (interval
   union) and `job.publish` reporting. `cleanup`/`summarize` are untouched.

## Failure model

- **Service-worker eviction / reconnect mid-meeting:** reconnect → `hello` → `subscribe`
  snapshot → re-declare via idempotent `meeting.start` if the DOM says a call is live. Ingest
  streams re-open lazily as PCM arrives (unchanged).
- **Daemon restart mid-meeting:** meeting state reloads from `meeting.toml`; clients detect the
  restart via `boot_id` and re-converge exactly as above. At most the in-flight mutation is lost.
- **Two frontends concurrently:** lifecycle verbs are idempotent and converge; snapshot+`rev`
  keeps every subscriber within one event of truth; `if_rev` makes rename a safe compare-and-set
  instead of silent last-write-wins.

## Verification (when implemented)

- **Golden wire fixtures** shared by the Swift and TypeScript test suites: the same JSON frames
  decoded/encoded by both sides, so the two `Codable`/TS codecs can never drift.
- `browser/dev/stub-server.ts` updated to speak v2 for extension tests.
- Daemon tests: idempotent `meeting.start`; pause/resume interval bookkeeping (capture provably
  untouched); restart recovery of an active meeting; orphan grace timer (streams closed → grace
  elapses → ended with `reason="ingest-idle"`; re-open within grace → still active); snapshot +
  `rev` gap detection with telemetry kinds filtered; per-transport capability enforcement;
  `[speakers]` write-back at `meeting.end`.
- `transcribe` test: `--meeting` unions intervals (paused span provably absent from output) and
  publishes `job` events through the daemon.
- Extension test: service-worker kill mid-meeting recovers via `hello` + `subscribe` with no
  duplicated or dropped meeting.

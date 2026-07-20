# Spec: `earsd` (capture daemon) + `ears` (control client)

## `earsd` — one job

Continuously capture every enabled audio source into its per-source ring buffer, maintain the VAD index, keep session and meeting records, and expose the control plane. `earsd` is the **only writer** to the ring buffer and is **never in the read path**.

### Responsibilities

- Open and manage a capture engine per enabled source (mic, system, per-app, device) and accept pushed audio for `browser:` sources.
- Encode incoming audio and append time-stamped chunks (native + 16 kHz ASR feeds) to `<data-root>/sources/<id>/`.
- Run a per-source VAD and append `chunk`/`vad`/`gap`/`evict` events to `index.jsonl`.
- Enforce each source's time cap by evicting oldest chunks; honour the optional `hard_total_cap_bytes` backstop.
- Maintain session and meeting descriptors; run app-signal triggers and the `on_close` pipeline.
- Serve the control plane: query, source management, session lifecycle, live-feed pub/sub, audio ingestion.

### Explicit non-responsibilities

- Does **not** transcribe, run models, or call LLMs (it only *spawns* the pipeline tools on trigger).
- Does **not** serve reads of audio or transcripts — consumers read files directly.

### Audio capture

- **Mic / device:** `AVAudioEngine` input, or Core Audio HAL for a specific device UID.
- **System / per-app audio:** Core Audio **process taps** (`CATap`, macOS 14.4+): build a `CATapDescription` → `AudioHardwareCreateProcessTap` → wrap in a private auto-start **tap-only aggregate device** (no sub-device, to avoid duplicate/echo audio) for a clean IO proc. The tap's format is read from `kAudioTapPropertyFormat`, never assumed. ScreenCaptureKit is rejected for this: it can't isolate per-app audio and forces a screen-recording prompt.
  - **Per-app scoping** (`app:<bundle-id>`) uses the tap's process-inclusion list: the daemon resolves a bundle id to its live PIDs, tracks process launch/exit, and rebuilds the inclusion list as the app's processes come and go. Inclusion/exclusion semantics are covered by integration tests; full isolation verification needs an opt-in test on real hardware with the permission granted.
- **Browser audio:** binary PCM pushed over the ingest WebSocket (below) into `browser:<label>` sources via a push-fed capture backend.
- **Realtime → worker hand-off:** the IO-proc is allocation-free and only publishes into the per-source lock-free SPSC RAM ring ([architecture](../architecture.md#two-buffers-kept-distinct)); a separate worker drains it to encode and write chunks. A dropped-sample counter is logged; sustained backpressure fails the stream rather than buffering unbounded.
- **Sources stay separately labelled to the very end** — mixing mic + system into one stream would discard you-vs-them attribution.

### Device-route resilience

- Derive frame count from the live `AudioBuffer` layout, not `ASBD.mBytesPerFrame`.
- Watch for default-device changes and rebuild the engine (with backoff), preserving the open chunk file.
- Debounce Bluetooth format-change notifications and dispose the audio unit before releasing the callback context, to survive AirPods-style route flaps.

### Permissions and TCC probing

- There is **no query API** for the system-audio tap's TCC grant. The daemon detects it by creating and destroying a throwaway tap, and by detecting the all-zero PCM stream a denied tap returns.
- On denial, the error names the exact pane — macOS 15's "System Audio Recording Only" sub-pane — rather than failing generically.
- Missing permission for a source logs an error and **disables just that source**, never the daemon.

### Ring buffer maintenance

- Chunks are fixed-duration (default 30 s), written atomically (temp + rename) then indexed. On flush, `fsync` both the file and its directory; on an encode failure, keep the partial chunk.
- Eviction: on each new chunk, delete chunks whose end is older than `now - time_cap` and emit `evict`. If `hard_total_cap_bytes > 0`, evict oldest across sources until under budget.
- On startup after downtime, emit a `gap` event covering the uncaptured interval.

### VAD

- An energy-threshold VAD runs per source on the captured stream, emitting coarse speech/silence spans with the configured padding/min-silence. (The `[earsd.vad].backend` key exists for a future model-based VAD; it is currently ignored.)
- This is an *index for skipping silence*, not a recording gate — all audio is still written.

### Triggers

- `[[triggers.rule]]` with `on = "app-audio-active"` opens a session when a matched app's own `app:<bundle-id>` source VAD goes to speech (genuine audio activity, not mere launch), and closes it when the app's last process exits.
- On close, the rule's `on_close` list (`transcribe`, `cleanup`, `summarize`) is spawned in order over the session. `pre_roll_seconds` widens `transcribe`'s read range backward without rewriting the session's `start`.
- Browser meeting sessions can run the same pipeline on close via `[triggers].transcribe_on_browser_session_close`.

### Lifecycle

- Designed to run as a launchd `LaunchAgent` (`KeepAlive`, `RunAtLoad`). The daemon generates the plist content; registration is currently a manual step — see [distribution](../distribution.md).
- Clean shutdown flushes the encode queue, closes chunks, and writes a final index flush. `SIGTERM` is graceful; `SIGKILL` recovery relies on atomic writes, so at most the in-flight chunk is lost.
- **Power/idle awareness:** system sleep, display sleep, and screen lock are independent suspension sources (a wake-while-locked stays suspended). Capture pauses on sleep and resumes on wake, recording a `gap` for the suspended interval.

### Footprint budget

- Idle (sources silent): negligible CPU beyond the VAD; a low, flat resident memory baseline with no growth over multi-day runs. Memory must not scale with buffer length on disk — the buffer is files, not RAM. Verified manually per the [soak runbook](../operations/capture-soak-runbook.md).

## Control protocol

> A redesigned v2 contract — id-correlated envelope, `hello` handshake, snapshot-on-subscribe, a daemon-owned meeting lifecycle — is specified in [`control-protocol.md`](./control-protocol.md) and not yet implemented. This section describes the wire as built.

Newline-delimited JSON request/response; responses are matched FIFO per connection. After `subscribe`, a connection becomes an event stream.

```jsonc
// --> request
{"cmd":"status"}
// <-- response
{"ok":true,"data":{"uptime_s":3600,"sources":[{"id":"mic","state":"capturing","codec":"aac"}]}}
```

Commands:

| `cmd` | Effect |
|-------|--------|
| `status` | Daemon + per-source state, buffer occupancy, active sessions. |
| `sources.list` | All configured sources and state. |
| `sources.add` / `sources.remove` | Add/remove a source at runtime. |
| `sources.enable` / `sources.disable` | Start/stop capturing a source. |
| `capture.pause` / `capture.resume` | Pause/resume a source, or all when omitted (records a `gap`). |
| `session.open` | Open a session: `{sources, slug, start?, vocab?, trigger?}` → session id. |
| `session.close` | Close a session by id. |
| `session.list` | Open/recent sessions. |
| `session.add_source` | Attach a source to an open session (e.g. a participant joining mid-call). |
| `meeting.resolve` | `{platform, external_id}` → the daemon-minted meeting UUID, idempotent per pair. Persists `meetings/<uuid>/meeting.toml`; callers use the UUID as their session slug so rejoins correlate. |
| `mark` | Retroactively define a range (e.g. "last 30m") as a session. |
| `ingest.open` / `ingest.close` | Rejected on the control transports with a pointer to the ingest WebSocket (below). |
| `segment.publish` | Publish one finalised `segment` event onto the live feed: `{session, speaker, start, end, text}`. Sent by a `transcribe --follow` process. Notification only — the daemon persists nothing; the durable transcript is the publisher's file. |
| `flush` | Finalize and index each enabled source's in-progress chunk, then open a fresh one. |

### Transports

The same command set is served on two transports, dispatched through one handler:

- **Unix domain socket** (`socket_path`, default `<data_root>/runtime/earsd.sock`) — the privileged plane for the CLI and pipeline tools, gated by filesystem permissions.
- **Control WebSocket** (`ws://127.0.0.1:<port>/control`, `[earsd.control_ws]`, off by default) — the browser extension's route. Text frames carry the same JSON; binary frames are rejected. The `Origin` header is validated against `allowed_origins` *before* the upgrade completes; an empty allowlist rejects everything (fail closed). Browsers set `Origin` truthfully, so this keeps web pages out even though the port is open.

### Audio ingestion (`/ingest` WebSocket)

Browser audio does **not** flow over the control transports — it uses a dedicated loopback WebSocket (`ws://127.0.0.1:<port>/ingest`, `[earsd.ingest_ws]`, off by default), with the same fail-closed Origin allowlist. It is **ingest-only**: `ingest.open`/`ingest.close` as text frames, PCM as binary frames, and every other command (including `subscribe`) rejected — an allowed origin still cannot drive the daemon from here.

```jsonc
// text --> declare a stream
{"cmd":"ingest.open","source":"browser:meet:jane-a1b2","format":{"sample_rate":16000,"channels":1,"encoding":"pcm_s16le"}}
// text <-- {"ok":true,"data":{"stream_id":"s7"}}
// text --> {"cmd":"ingest.close","stream_id":"s7"}
```

Audio is one binary frame per PCM chunk, multiplexed by `stream_id` (no sequence number — WebSocket rides TCP):

```
[ u8 idLen ][ stream_id : idLen ASCII bytes ][ pcm_s16le bytes (mono, little-endian) ]
```

A `browser:<label>` source is created lazily on its first-ever `ingest.open` and persists for the daemon's lifetime; a later `ingest.open` for the same label (a participant rejoining) resumes the same on-disk source. `ingest.close` flushes and indexes the in-progress chunk. The client side is specified in [browser/transport.md](./browser/transport.md), which this endpoint matches wire-for-wire.

Both WebSocket servers are hand-rolled on the raw socket transport rather than `NWProtocolWebSocket`, which offers no hook to validate `Origin` before completing the upgrade.

### Live feed (pub/sub)

```jsonc
// --> {"cmd":"subscribe","events":["vad","session","segment"],"sources":["mic"]}
// <-- stream of events:
{"ev":"vad","source":"mic","state":"speech","t":"2026-07-17T10:30:02.14Z"}
{"ev":"session","id":"...standup","state":"open"}
{"ev":"segment","session":"...standup","speaker":"You","start":604.1,"end":611.9,"text":"..."}
```

Subscribing is terminal for the connection. Events are notification-only with a bounded per-subscriber queue (drop-oldest); a late subscriber gets no replay — durable state lives on disk.

## `ears` — control client

Thin CLI over the Unix socket. One job: let a human or a script drive the daemon.

```
ears status
ears sources list
ears sources enable app:us.zoom.xos
ears capture pause [<source>]
ears session open --slug standup --source mic --source app:us.zoom.xos
ears session close <id>
ears mark --last 30m --slug hallway-chat        # retroactive session
ears watch --events vad,segment                 # subscribe and print the live feed
ears flush
ears config show / ears config path
```

Every subcommand has concise `--help`. Output is human-readable by default, `--json` for scripting. Exits non-zero with a clear message if the daemon is unreachable.

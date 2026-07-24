# Spec: `earsd` (capture daemon) + `ears` (control client)

## `earsd` — one job

Capture each active meeting's audio sources under the meeting's own directory, maintain the VAD index, keep session and meeting records, enforce transcript-driven retention, and expose the control plane. `earsd` is the **only writer** to the audio store and is **never in the read path**.

### Responsibilities

- Open and manage a capture engine per source a meeting names (mic, system, per-app, device) and accept pushed audio for `browser:` sources — built when a meeting starts, torn down when its last meeting ends. The daemon boots idle and records nothing between meetings.
- Encode incoming audio and append time-stamped chunks (native + 16 kHz ASR feeds) to `<data-root>/meetings/<meeting-id>/sources/<id>/`.
- Run a per-source VAD and append `chunk`/`gap` events to the structural index (`chunks.jsonl`) and `vad` spans to the segmented VAD stream (`vad/`) — see [data formats](../data-formats.md#the-index-chunksjsonl--vad).
- Enforce transcript-driven retention: delete an ended meeting's audio once its deadline passes (below).
- Maintain session and meeting descriptors; run app-signal triggers and the `on_close` pipeline.
- Serve the control plane: query, source management, session lifecycle, live-feed pub/sub, audio ingestion.

### Explicit non-responsibilities

- Does **not** transcribe, run models, or call LLMs (it only *spawns* the pipeline tools on trigger).
- Does **not** serve reads of audio or transcripts — consumers read files directly.

### Audio capture

- **Mic / device:** `AVAudioEngine` input follows the system default input by default — whatever device the user has selected, Bluetooth included. Recording is meeting-scoped and brief, so holding a Bluetooth mic open for a call is acceptable and there is no built-in-mic preference. Selection (`InputDeviceSelection`): an explicit `device_uid` binds that specific device; with none set, the engine stays on the system default. **Crash-safe binding:** the device is set on the input node's audio unit (`kAudioOutputUnitProperty_CurrentDevice`) on a fresh, not-yet-started engine, *before* the tap is installed and `start()` runs — never on a live node via `AUAudioUnit.setDeviceID`, which crashed AVFoundation (`AVAudioIOUnit::IOUnitPropertyListener` use-after-free racing the route-change/stall rebuild). Binding still provokes one self-induced `AVAudioEngineConfigurationChange` at start, so the backend suppresses configuration-change rebuilds within a short settle window after each (re)build; genuine route changes outside that window rebuild as before. Binding is best-effort — no `device_uid`, an inaccessible audio unit, or a failed HAL set all fall back to the system default input. Needs the real-hardware verification pass (below) before it is trusted in a release.
- **System / per-app audio:** Core Audio **process taps** (`CATap`, macOS 14.4+): build a `CATapDescription` → `AudioHardwareCreateProcessTap` → wrap in a private auto-start **tap-only aggregate device** (no sub-device, to avoid duplicate/echo audio) for a clean IO proc. The tap's format is read from `kAudioTapPropertyFormat`, never assumed. ScreenCaptureKit is rejected for this: it can't isolate per-app audio and forces a screen-recording prompt.
  - **Per-app scoping** (`app:<bundle-id>`) uses the tap's process-inclusion list: the daemon resolves a bundle id to its live PIDs, tracks process launch/exit, and rebuilds the inclusion list as the app's processes come and go. Inclusion/exclusion semantics are covered by integration tests; full isolation verification needs an opt-in test on real hardware with the permission granted.
- **Browser audio:** binary PCM pushed over the ingest WebSocket (below) into `browser:<label>` sources via a push-fed capture backend.
- **Realtime → worker hand-off:** the IO-proc is allocation-free and only publishes into the per-source lock-free SPSC RAM buffer ([architecture](../architecture.md#two-stores-kept-distinct)); a separate worker drains it to encode and write chunks. A dropped-sample counter is logged; sustained backpressure fails the stream rather than buffering unbounded.
- **Sources stay separately labelled to the very end** — mixing mic + system into one stream would discard you-vs-them attribution.

### Device-route resilience

- Derive frame count from the live `AudioBuffer` layout, not `ASBD.mBytesPerFrame`.
- Watch for default-device changes and rebuild the engine (with backoff), preserving the open chunk file.
- Debounce Bluetooth format-change notifications and dispose the audio unit before releasing the callback context, to survive AirPods-style route flaps.
- **Input sample-rate switch mid-recording** (e.g. a Bluetooth headset engaging HFP at 16 kHz, replacing the 48 kHz built-in mic): every incoming buffer is normalised to the source's configured native rate before VAD/encode, and the switch is made an **explicit chunk boundary** — the chunk accumulating at the old rate is finalized and the new rate starts a fresh, single-rate chunk (the resampler's converter is rebuilt for the new input rate). The `capture.input_rate_changed` log records the action taken (`chunk_finalized`/`converter_rebuilt`/`baseline`), never a silent continue-in-place, which previously produced an `.m4a` `ExtAudioFileOpenURL` later refused to open.
- **Post-write validity check:** each finalized chunk's `asr/` file is reopened with the same decoder `transcribe` uses, and `capture.chunk_finalized` logs its path, declared sample rate, frame count, and the open-check result — so an unreadable chunk is flagged at write time, not at transcription time.

### Permissions and TCC probing

- There is **no query API** for the system-audio tap's TCC grant. The daemon detects it by creating and destroying a throwaway tap, and by detecting the all-zero PCM stream a denied tap returns.
- On denial, the error names the exact pane — macOS 15's "System Audio Recording Only" sub-pane — rather than failing generically.
- Missing permission for a source logs an error and **disables just that source**, never the daemon.

### Storage maintenance and retention

- Chunks are fixed-duration (default 30 s), written atomically (temp + rename) then indexed. On flush, `fsync` both the file and its directory; on an encode failure, keep the partial chunk.
- Retention is per-meeting, driven by `[earsd.retention]`: a daemon-owned periodic sweep (default every 60 s) deletes an **ended** meeting's whole `sources/` directory once `transcript_completed + evict_after_transcript_seconds` has passed — or, when no transcript ever completed, once `ended + max_audio_age_seconds` has (so a failed transcription can be retried up to that point). `meeting.toml` and `events.jsonl` are never deleted; transcripts under `<output-root>` are never deleted. Live meetings are never touched.
- The transcript-completion marker is stamped by the daemon when the meeting-end auto-transcribe exits 0 (persisted as `transcript_completed` in `meeting.toml`), so retention survives restarts.

### VAD

- An energy-threshold VAD runs per source on the captured stream, emitting coarse speech/silence spans with the configured padding/min-silence. (The `[earsd.vad].backend` key exists for a future model-based VAD; it is currently ignored.)
- This is an *index for skipping silence*, not a recording gate — all audio is still written.

### Triggers

- `[[triggers.rule]]` with `on = "app-audio-active"` opens a session when a matched app's own `app:<bundle-id>` source VAD goes to speech (genuine audio activity, not mere launch), and closes it when the app's last process exits.
- On close, the rule's `on_close` list (`transcribe`, `cleanup`, `summarize`) is spawned in order over the session. `pre_roll_seconds` widens `transcribe`'s read range backward without rewriting the session's `start`.
- Browser meeting sessions run the same pipeline on close by default via `[triggers].transcribe_on_browser_session_close` (set `false` to disable).

### Lifecycle

- Designed to run as a launchd `LaunchAgent` (`KeepAlive`, `RunAtLoad`). The daemon generates the plist content; registration is currently a manual step — see [distribution](../distribution.md).
- Clean shutdown flushes the encode queue, closes chunks, and writes a final index flush. `SIGTERM` is graceful; `SIGKILL` recovery relies on atomic writes, so at most the in-flight chunk is lost.
- **Power/idle awareness:** system sleep, display sleep, and screen lock are independent suspension sources (a wake-while-locked stays suspended). Capture pauses on sleep and resumes on wake, recording a `gap` for the suspended interval.

### Footprint budget

- Idle (sources silent): negligible CPU beyond the VAD; a low, flat resident memory baseline with no growth over multi-day runs. Memory must not scale with buffer length on disk — the buffer is files, not RAM. Verified manually per the [soak runbook](../operations/capture-soak-runbook.md).

## Control protocol

The control contract — the id-correlated `{id, method, params}` envelope, the mandatory `hello`
handshake, per-transport capability tiers, the daemon-owned **Meeting** entity, and
snapshot-on-subscribe state sync — is specified in [`control-protocol.md`](control-protocol.md)
(control protocol v2, the implemented wire). Identical frames are served over the Unix domain
socket (newline-delimited JSON, full privilege) and the loopback control WebSocket
(`[earsd.control_ws]`, `observe` + `meetings` only). This section keeps only what is *not* part
of that contract: the audio-ingestion WebSocket, which is deliberately out of v2's scope and
unchanged.

### Request/response (see control-protocol.md)

```jsonc
// --> request
{"id": 7, "method": "status"}
// <-- response
{"id": 7, "result": {"uptime_s": 3600, "sources": [{"id": "mic", "state": "capturing", "codec": "aac"}], "meetings": [], "sessions": []}}
```

The full method table — `meeting.*` lifecycle verbs included — lives in
[`control-protocol.md`](control-protocol.md#methods).

### Transports

The same command set is served on two transports, dispatched through one handler:

- **Unix domain socket** (`socket_path`, default `<data_root>/runtime/earsd.sock`) — the privileged plane for the CLI and pipeline tools, gated by filesystem permissions.
- **Control WebSocket** (`ws://127.0.0.1:<port>/control`, `[earsd.control_ws]`, off by default) — the browser extension's route. Text frames carry the same JSON; binary frames are rejected. The `Origin` header is validated against `allowed_origins` *before* the upgrade completes; an empty allowlist rejects everything (fail closed). Browsers set `Origin` truthfully, so this keeps web pages out even though the port is open.

### Audio ingestion (`/ingest` WebSocket)

Browser audio does **not** flow over the control transports — it uses a dedicated loopback WebSocket (`ws://127.0.0.1:<port>/ingest`, `[earsd.ingest_ws]`, off by default), with the same fail-closed Origin allowlist. It is **ingest-only**: `ingest.open`/`ingest.close` as text frames, PCM as binary frames, and every other command (including `subscribe`) rejected — an allowed origin still cannot drive the daemon from here.

```jsonc
// text --> declare a stream (the optional `meeting` tag names the membership)
{"cmd":"ingest.open","source":"browser:meet:jane-a1b2","format":{"sample_rate":16000,"channels":1,"encoding":"pcm_s16le"},"meeting":{"platform":"meet","external_id":"abc-defg-hij"}}
// text <-- {"ok":true,"data":{"stream_id":"s7"}}
// text --> {"cmd":"ingest.close","stream_id":"s7"}
```

The optional `meeting` field carries the meeting identity (`meeting.start`'s idempotency key) the source belongs to. The daemon links the source into that live meeting's `sources` itself — stashing the link until the `meeting.start` lands, if the open raced ahead of it — so the ingest-idle grace policy holds even when the extension's own `meeting.attendee` source upserts never arrive (an MV3 service worker respawned mid-call has no meeting state to upsert from). The client's attendee upserts remain the enrichment path (attributing a source to a named attendee); the tag is the membership path. Untagged opens behave exactly as before.

Audio is one binary frame per PCM chunk, multiplexed by `stream_id` (no sequence number — WebSocket rides TCP):

```
[ u8 idLen ][ stream_id : idLen ASCII bytes ][ pcm_s16le bytes (mono, little-endian) ]
```

A `browser:<label>` source is created lazily on its first-ever `ingest.open` and persists for the daemon's lifetime; a later `ingest.open` for the same label (a participant rejoining) resumes the same on-disk source. `ingest.close` flushes and indexes the in-progress chunk. The client side is specified in [browser/transport.md](./browser/transport.md), which this endpoint matches wire-for-wire.

PCM frames carry no timestamps, and a pushed stream may go quiet at will (Meet's per-speaker streams deliver audio only while that speaker talks). Chunk/VAD timestamps normally accumulate from delivered audio duration, so the daemon re-anchors the source's timeline to wall clock whenever delivery resumes after a stall of more than ~2s, recording the quiet interval as a `gap` (`reason:"delivery-stall"`). Without this, every silence would be squeezed out of the timeline and the source's chunks would be stamped progressively further behind wall clock — mis-interleaving its transcript against continuously-captured sources. Sub-threshold jitter stays on the accumulated timeline.

Both WebSocket servers are hand-rolled on the raw socket transport rather than `NWProtocolWebSocket`, which offers no hook to validate `Origin` before completing the upgrade.

### Live feed (pub/sub)

`subscribe`'s result is a **snapshot** of live state tagged with a monotonic revision; state
events (`meeting`, `session`, `source`) arrive revision-tagged and telemetry events (`vad`,
`segment`, `job`) untagged — see [`control-protocol.md`](control-protocol.md#state-sync).

```jsonc
// --> {"id": 1, "method": "subscribe", "params": {"events": ["vad", "segment"]}}
// <-- {"id": 1, "result": {"rev": 41, "meetings": […], "sources": […], "sessions": […]}}
{"event":"vad","params":{"source":"mic","state":"speech","t":"2026-07-17T10:30:02.14Z"}}
{"event":"segment","params":{"session":"...standup","speaker":"You","start":604.1,"end":611.9,"text":"..."}}
```

`segment` events originate from a `transcribe --follow` process that publishes back to the daemon (the `segment.publish` method), letting many consumers watch one live transcript; `job` events likewise republish `job.publish` progress from a meeting-level transcribe run. The socket is notification only: a subscriber that connects late gets the snapshot, not history — the durable record is on disk.

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

# Spec: `earsd` (capture daemon) + `ears` (control client)

## `earsd` — one job

Capture each active session's audio sources under the session's own directory, maintain the VAD index, keep session records, enforce transcript-driven retention, and expose the control plane. `earsd` is the **only writer** to the audio store and is **never in the read path**.

### Responsibilities

- Open and manage a capture engine per source a session names (mic, system, per-app, device) and accept pushed audio for `browser:` sources — built when a session starts, torn down when it ends. The daemon boots idle and records nothing between sessions.
- Encode incoming audio and append time-stamped chunks (native + 16 kHz ASR feeds) to `<data-root>/sessions/<session-id>/sources/<id>/`.
- Run a per-source VAD and append `chunk`/`gap` events to the structural index (`chunks.jsonl`) and `vad` spans to the segmented VAD stream (`vad/`) — see [data formats](../data-formats.md#the-index-chunksjsonl--vad).
- Enforce transcript-driven retention: delete an ended session's audio once its deadline passes (below).
- Own the session lifecycle ([control protocol v2](control-protocol.md#session)) and spawn the session-end pipeline (`on_end_stages`).
- Serve the control plane: query, source management, session lifecycle, live-feed pub/sub, audio ingestion.

### Explicit non-responsibilities

- Does **not** transcribe, run models, or call LLMs (it only *spawns* the pipeline tools on trigger).
- Does **not** serve reads of audio or transcripts — consumers read files directly.

### Audio capture

- **Mic / device:** `AVAudioEngine` input follows the system default input by default — whatever device the user has selected, Bluetooth included. Recording is session-scoped and brief, so holding a Bluetooth mic open for a call is acceptable and there is no built-in-mic preference. Selection (`InputDeviceSelection`): an explicit `device_uid` binds that specific device; with none set, the engine stays on the system default. **Crash-safe binding:** the device is set on the input node's audio unit (`kAudioOutputUnitProperty_CurrentDevice`) on a fresh, not-yet-started engine, *before* the tap is installed and `start()` runs — never on a live node via `AUAudioUnit.setDeviceID`, which crashed AVFoundation (`AVAudioIOUnit::IOUnitPropertyListener` use-after-free racing the route-change/stall rebuild). Binding still provokes one self-induced `AVAudioEngineConfigurationChange` at start, so the backend suppresses configuration-change rebuilds within a short settle window after each (re)build; genuine route changes outside that window rebuild as before. Binding is best-effort — no `device_uid`, an inaccessible audio unit, or a failed HAL set all fall back to the system default input. Needs the real-hardware verification pass (below) before it is trusted in a release.
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
- Retention is per-session, driven by `[earsd.retention]`: a daemon-owned periodic sweep (default every 60 s) deletes an **ended** session's whole `sources/` directory once `transcript_completed + evict_after_transcript_seconds` has passed — or, when no transcript ever completed, once `ended + max_audio_age_seconds` has (so a failed transcription can be retried up to that point). `session.toml` and `events.jsonl` are never deleted. Live sessions are never touched.
- The transcript-completion marker is stamped by the daemon when the session-end auto-transcribe exits 0 (persisted as `transcript_completed` in `session.toml`), so retention survives restarts.
- **Transcripts are never swept, in either tier.** Published artifacts under `output_root` are the user's files. The *raw* transcript in the session's own directory (`sessions/<uuid>/transcript.md`) is deliberately kept too, even though it lives inside the store the sweep runs over: once the audio is evicted it is the only route to re-running cleanup or summarize with a different prompt or model. The sweep deletes `sources/` and nothing else.

### VAD

- An energy-threshold VAD runs per source on the captured stream, emitting coarse speech/silence spans with the configured padding/min-silence. (The `[earsd.vad].backend` key exists for a future model-based VAD; it is currently ignored.)
- This is an *index for skipping silence*, not a recording gate — all audio is still written.

### Session-end pipeline

- **Reconciliation runs first**, before any stage: the daemon derives the session's speaker map from its final roster, applying the invariants in [data-formats "Roster and speaker map"](../data-formats.md#roster-and-speaker-map), and persists it to `session.toml` alongside any `warnings`. Doing it at end rather than live means it sees the whole call — an attendee who joined late, a binding made and then contradicted — instead of deciding on partial evidence and never revisiting it. It is a pure function of the roster, so `transcribe --session` re-derives it on demand for a session that has none.
- **Title precedence: window title first.** A session still carrying the platform default (`meet wUE9lE2sg5YB`) is retitled from its roster — the other participants' names — because that default is unreadable in a file listing, unsearchable, and guaranteed not to match the note a user filed under a person's name. A meeting name scraped from the window title (the extension's `MeetMeetingTitleWatcher` → `session.rename`) and a rename typed by hand both outrank it, simply by having changed the title away from the default. The default is regenerated and compared rather than tracked with a flag, so the ordering needs no extra state.
- Recording is session-scoped and sessions are started deliberately (browser extension or CLI); there are no automatic capture triggers.
- Browser-triggered sessions run the `[earsd.sessions] on_end_stages` chain automatically when they end (default `transcribe` → `cleanup` → `summarize`): the daemon spawns `transcribe --session <id> --json`, feeds the transcript path to `cleanup … --json`, and the cleaned path to `summarize … --select-preset --json` (one preset per session, chosen by classifying the transcript against each preset's `when`). Manual sessions run the pipeline by hand.
- The daemon speaks the versioned `--json` result envelope (see [llm-stages "Result envelopes"](llm-stages.md#result-envelopes---json)): each stage's stdout is exactly one envelope document whose `output` feeds the next stage, so the daemon never re-derives a stage's output-path logic. The parse is strict — stdout pollution, a wrong schema major (the log names both identifiers), or `ok: false` under exit 0 fails the stage; unknown envelope keys are ignored (the minor-version policy) — and the envelope's `output` must exist on disk before it feeds the next stage, so a stale or lying path dies at this seam instead of two stages later.
- Each stage's stderr is captured (bounded) for the daemon log — on success as well as failure. A successful stage's capture is filtered to its plain-text lines (its JSON-Lines log records are dropped, the daemon log already carrying them by every other route), so a stage that exits 0 *having degraded* still says so: `summarize reported for session '…': warning: preset 'meeting': no notes file at …`. Exit 0 previously discarded the whole capture, which is how a run that could not find the notes it was configured to fold in, summarized without them, and overwrote that path anyway, logged nothing but `summarize wrote 1/1 presets`. A failure line carries the exit code with its taxonomy class label (`cleanup failed (exit 5, retryable-upstream)`; codes outside the taxonomy log `unclassified`), augmented with the stderr error envelope's `exit_class` and `message` when its last line decodes as one. Summarize's per-preset results are logged from its envelope's `outputs[]` — `summarize wrote 2/3 presets (failed: actions)` — on success and failure alike.
- **The chain stops after transcribe when the transcript is empty.** A session that recorded only background audio still transcribes, into a document with nothing in it, and the LLM stages downstream invent content from that and publish the invention: the 2026-08-20 `c08595c8` session ran 605 seconds, transcribed to the single word `Yeah.`, and its summary — speculating in prose about whether the meeting had happened — was written over an unrelated daily note. The gate reads the fresh transcript's own `word_count` and `speech_seconds`; below `[earsd.sessions] min_words` (default 10) *or* `min_speech_seconds` (default 5), `cleanup` and `summarize` are skipped and the daemon logs one line naming the measurements against the thresholds. Either threshold at `0` disables that half; both at `0` runs the chain unconditionally. A skipped chain is a *successful* chain — the transcript is still written and `transcript_completed` is still stamped, so audio retention is unaffected — and `ears session show` renders the skipped stages as `skipped (empty transcript)` rather than as missing artifacts.
- The chain stops loudly at the first failing stage. On transcribe exit 0 — and regardless of what the LLM stages do afterwards — the daemon stamps the session's `transcript_completed` marker, which starts the retention clock: the raw transcript is the durable artifact, and derived stages never gate retention.
- Each chain run records what its stages reported as the session's `pipeline_issues`: a failed stage (its error message and exit class) and each `warning:` line a successful stage wrote. A new run replaces the list. `ears sessions` names the failed stage and class (`✗ transcribed, summarize failed (retryable-upstream)`), `ears session show` prints the message in that stage's row, and stage warnings count toward the warnings total.
- A successful summarize also records the paths it wrote as the session's `published_notes`. summarize excludes every other session's list when it searches for a call's jotted notes. A failed run leaves the list unchanged, because the earlier note is still on disk.

### Lifecycle

- Designed to run as a launchd `LaunchAgent` (`KeepAlive`, `RunAtLoad`). The daemon generates the plist content; registration is currently a manual step — see [distribution](../distribution.md).
- Clean shutdown flushes the encode queue, closes chunks, and writes a final index flush. `SIGTERM` is graceful; `SIGKILL` recovery relies on atomic writes, so at most the in-flight chunk is lost.
- **Power/idle awareness:** system sleep, display sleep, and screen lock are independent suspension sources (a wake-while-locked stays suspended). Capture pauses on sleep and resumes on wake, recording a `gap` for the suspended interval.

### Footprint budget

- Idle (sources silent): negligible CPU beyond the VAD; a low, flat resident memory baseline with no growth over multi-day runs. Memory must not scale with buffer length on disk — the buffer is files, not RAM. Verified manually per the [soak runbook](../operations/capture-soak-runbook.md).

## Control protocol

The control contract — the id-correlated `{id, method, params}` envelope, the mandatory `hello`
handshake, per-transport capability tiers, the daemon-owned **Session** entity, and
snapshot-on-subscribe state sync — is specified in [`control-protocol.md`](control-protocol.md)
(control protocol v2, the implemented wire). Identical frames are served over the Unix domain
socket (newline-delimited JSON, full privilege) and the loopback control WebSocket
(`[earsd.control_ws]`, `observe` + `sessions` only). This section keeps only what is *not* part
of that contract: the audio-ingestion WebSocket, which is deliberately out of v2's scope.

### Request/response (see control-protocol.md)

```jsonc
// --> request
{"id": 7, "method": "status"}
// <-- response
{"id": 7, "result": {"uptime_s": 3600, "sources": [{"id": "mic", "state": "capturing", "codec": "aac"}], "sessions": []}}
```

The full method table — `session.*` lifecycle verbs included — lives in
[`control-protocol.md`](control-protocol.md#methods).

### Transports

The same command set is served on two transports, dispatched through one handler:

- **Unix domain socket** (`socket_path`, default `<data_root>/runtime/earsd.sock`) — the privileged plane for the CLI and pipeline tools, gated by filesystem permissions.
- **Control WebSocket** (`ws://127.0.0.1:<port>/control`, `[earsd.control_ws]`, off by default) — the browser extension's route. Text frames carry the same JSON; binary frames are rejected. The `Origin` header is validated against `allowed_origins` *before* the upgrade completes; an empty allowlist rejects everything (fail closed). Browsers set `Origin` truthfully, so this keeps web pages out even though the port is open.

### Audio ingestion (`/ingest` WebSocket)

Browser audio does **not** flow over the control transports — it uses a dedicated loopback WebSocket (`ws://127.0.0.1:<port>/ingest`, `[earsd.ingest_ws]`, off by default), with the same fail-closed Origin allowlist. It is **ingest-only**: `ingest.open`/`ingest.close`/`ingest.attribution`/`ingest.capture_failed` as text frames, PCM as binary frames, and every other command (including `subscribe`) rejected — an allowed origin still cannot drive the daemon from here.

```jsonc
// text --> declare a stream (the optional `session` tag names the membership)
{"cmd":"ingest.open","source":"browser:meet:jane-a1b2","format":{"sample_rate":16000,"channels":1,"encoding":"pcm_s16le"},"session":{"platform":"meet","external_id":"abc-defg-hij"}}
// text <-- {"ok":true,"data":{"stream_id":"s7"}}
// text --> {"cmd":"ingest.close","stream_id":"s7"}
```

The optional `session` field carries the session identity (`session.start`'s idempotency key: the platform plus the platform's own meeting id) the source belongs to. The daemon links the source into that live session's `sources` itself — stashing the link until the `session.start` lands, if the open raced ahead of it — so the ingest-idle grace policy holds even when the extension's own `session.attendee` source upserts never arrive (an MV3 service worker respawned mid-call has no session state to upsert from). The client's attendee upserts remain the enrichment path (attributing a source to a named attendee); the tag is the membership path. Untagged opens behave exactly as before.

Audio is one binary frame per PCM chunk, multiplexed by `stream_id`. Two shapes, discriminated by the first byte:

```
legacy:   [ u8 idLen>0 ][ stream_id : idLen ASCII ][ pcm_s16le (mono, LE) ]
extended: [ 0x00 ][ u8 ver=1 ][ u8 idLen ][ stream_id ][ u32le seq ][ f64le sentAt ][ pcm_s16le ]
```

A zero first byte cannot occur in the legacy shape — stream ids are never empty — which is what makes it a safe discriminator. The daemon parses both, so a daemon upgraded ahead of the extension keeps ingesting; only the delivery timing below degrades to `cause:"unknown"`.

`seq` is per-stream and monotonic (wrapping at 2^32); `sentAt` is epoch milliseconds at the moment the browser's MAIN world handed the frame over. WebSocket rides TCP, so these are not for reordering or retransmission — they exist because arrival times alone cannot distinguish a speaker who stopped talking from a capture path that died, and the daemon needs to log which one happened.

A `browser:<label>` source is created lazily on its first-ever `ingest.open` and persists for the daemon's lifetime; a later `ingest.open` for the same label (a participant rejoining) resumes the same on-disk source. `ingest.close` flushes and indexes the in-progress chunk. The client side is specified in [browser/transport.md](./browser/transport.md), which this endpoint matches wire-for-wire.

A pushed stream may go quiet at will (Meet's per-speaker streams deliver audio only while that speaker talks). Chunk/VAD timestamps normally accumulate from delivered audio duration, so the daemon re-anchors the source's timeline to wall clock whenever delivery resumes after a stall of more than ~2s, recording the quiet interval as a `gap` (`reason:"delivery-stall"`). Without this, every silence would be squeezed out of the timeline and the source's chunks would be stamped progressively further behind wall clock — mis-interleaving its transcript against continuously-captured sources. Sub-threshold jitter stays on the accumulated timeline.

The `capture.delivery_gap` record classifies each gap using the sender's stamp: `silence` (the sender's own clock shows the same gap), `delivery-stall` (frames were produced but arrived bunched), `frames-lost` (the sequence skipped), or `unknown` (legacy client). See [logging.md](../logging.md#performance-events).

Both WebSocket servers are hand-rolled on the raw socket transport rather than `NWProtocolWebSocket`, which offers no hook to validate `Origin` before completing the upgrade.

### Live feed (pub/sub)

`subscribe`'s result is a **snapshot** of live state tagged with a monotonic revision; state
events (`session`, `source`) arrive revision-tagged and telemetry events (`vad`,
`segment`, `job`) untagged — see [`control-protocol.md`](control-protocol.md#state-sync).

```jsonc
// --> {"id": 1, "method": "subscribe", "params": {"events": ["vad", "segment"]}}
// <-- {"id": 1, "result": {"rev": 41, "sessions": […], "sources": […]}}
{"event":"vad","params":{"source":"mic","state":"speech","t":"2026-07-17T10:30:02.14Z"}}
{"event":"segment","params":{"session":"0d5e…","speaker":"You","start":604.1,"end":611.9,"text":"..."}}
```

`segment` events originate from a `transcribe --follow` process that publishes back to the daemon (the `segment.publish` method), letting many consumers watch one live transcript; `job` events likewise republish `job.publish` progress from a session-level transcribe run. The socket is notification only: a subscriber that connects late gets the snapshot, not history — the durable record is on disk.

## `ears` — control client

Thin CLI over the Unix socket. One job: let a human or a script drive the daemon.

```
ears                                            # = ears status: the dashboard
ears status                                     # live sessions + their sources, recent outcomes
ears sessions [--all]                           # one line per session with its pipeline outcome;
                                                #   --all reads sessions/*/session.toml from disk
ears session show <ref> [--warnings] [--json]   # one session's pipeline, stage by stage, from disk;
                                                #   <ref> = id prefix | title fragment | HH:MM today
ears session start --title standup --source mic --source app:us.zoom.xos
ears session pause <session-id>                 # closes the open mark; capture untouched
ears session resume <session-id>                # opens a new mark
ears session rename <session-id> --title "Weekly sync"
ears session end <session-id>
ears session list [--all]                       # alias of `ears sessions`
ears sources list
ears sources enable app:us.zoom.xos
ears capture pause [<source>]
ears watch --events vad,segment                 # subscribe: snapshot, then the live feed
ears flush
ears config show / ears config path
```

Every subcommand has concise `--help`. Output is human-readable by default — `status` renders a dashboard that groups sources under the session they feed, labels them only with names the session's speaker map or roster provides, and ends with a short recent-sessions tail — with `--json` for scripting (`status` and `session list` keep their existing payload shapes; additions are additive-only). Exits non-zero with a clear message if the daemon is unreachable; `sessions --all` and `session show` read from disk and need no daemon at all.

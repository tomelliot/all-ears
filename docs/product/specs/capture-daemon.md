# Spec: `earsd` (capture daemon) + `ears` (control client)

## `earsd` — one job

Continuously capture every enabled audio source into its per-source ring buffer, maintain the VAD index, keep session records, and expose a control socket. `earsd` is the **only writer** to the ring buffer and is **never in the read path**.

### Responsibilities

- Open and manage a capture engine per enabled source (mic, system, per-app, device) and accept pushed audio for socket-ingested sources (browser plugin).
- Encode incoming audio and append time-stamped chunks to `<data-root>/sources/<id>/chunks/`.
- Run a per-source VAD and append `chunk`/`vad`/`gap`/`evict` events to `index.jsonl`.
- Enforce each source's time cap (default 2 h) by evicting oldest chunks; honour an optional hard total-size backstop.
- Maintain session descriptors on open/close.
- Serve the control socket: query, source management, session lifecycle, audio ingestion, live-feed pub/sub.

### Explicit non-responsibilities

- Does **not** transcribe, run models, or call LLMs.
- Does **not** serve reads of audio/transcripts — consumers read files directly.
- Does **not** decide *when* to transcribe — that's triggers/`ears`.

### Audio capture (native APIs)

- **Mic / device:** `AVAudioEngine` input node, or Core Audio HAL for a specific device UID.
- **System / per-app audio:** Core Audio **process taps** (`CATap`, macOS 14.4+). The recipe, consistent across the reference implementations (Recap, hyprnote): build a `CATapDescription` → `AudioHardwareCreateProcessTap` → wrap it in a **private auto-start aggregate device** to obtain a clean `AudioDeviceIOProcID`. Read the tap's format from `kAudioTapPropertyFormat` — never assume it. Use a **tap-only aggregate with no sub-device** to avoid duplicate/echo audio.
  - **ScreenCaptureKit is explicitly rejected** for system audio: it cannot isolate per-app audio, forces a Screen-Recording prompt, and drags in a dummy video pipeline. `CATap` is the validated choice for per-app separation.
- **Per-app scoping (`app:<bundle-id>`) — our differentiator, and the least-proven path.** Most tap users take the *global* tap and stop; per-app separation is what keeps meeting sources distinct, so `earsd` must exercise the tap's **process-inclusion list**. Inclusion/exclusion semantics are verified explicitly and behind integration tests (one surveyed tool's `processes = [own PID], isExclusive = true` is flagged as likely-wrong — do not copy it). Resolve a bundle id to its live PID(s), track process launch/exit, and rebuild the tap's inclusion list as the target app's processes come and go.
- **Browser plugin:** frames pushed over the control socket into a `browser:<label>` source.
- **Realtime → worker hand-off.** The IO-proc is allocation-free and only publishes into the per-source **lock-free SPSC RAM ring** ([architecture](../architecture.md#two-buffers-kept-distinct)); a separate `userInteractive` worker drains it to encode and write chunks. This RAM ring is the realtime jitter buffer — **not** the on-disk retroactive ring. Surface a **dropped-sample counter** in logs; under sustained backpressure, count consecutive drops and **fail the stream** rather than buffering unbounded.
- **Keep sources separately labelled to the very end.** Each source's samples stay tagged (`mic` vs `system` vs `app:*`) through capture, storage, and transcription — mixing mic + system into one stream (a surveyed mistake) discards you-vs-them attribution for free. Two free-running source clocks are aligned with a bounded per-source queue that silence-fills after N chunks of lag.

### Device-route resilience

- Derive frame count from the **live `AudioBuffer` layout**, not `ASBD.mBytesPerFrame` — getting this wrong causes a documented 3× playback-speed bug (FluidVoice).
- Watch for **default-input/output-device changes** and rebuild the engine while preserving the open output chunk file (Detto, Hex, typewhisper-mac patterns).
- **Debounce Bluetooth format-change** notifications and dispose the AUHAL before releasing the callback context, to survive AirPods-style route flaps.

### Permissions and TCC probing

- There is **no query API** for the system-audio tap's TCC grant. Detect it by **creating and destroying a throwaway tap** (pindrop), and by detecting the **all-zero PCM stream** that a TCC-denied tap returns.
- On denial, emit an actionable message naming the exact pane — macOS 15's "System Audio Recording Only" sub-pane — rather than a generic failure.
- Poll real permission state (`AXIsProcessTrusted`, `CGPreflight…`); never fake grant state with timers.
- Missing permission for a source logs an error and **disables just that source** — never takes down the daemon.

### Isolation option for the riskiest syscalls

The process tap is the most crash-prone surface. An optional design (livecaption's `audiotee` model) wraps the tap in a tiny external binary emitting **raw PCM on stdout + NDJSON status on stderr**, so a tap crash ≠ daemon crash, with a `select()`-based **stall watchdog + respawn** (a wedged tap yields no error and no EOF). Default is in-process for simplicity; if kept in-process, the **stall watchdog is still required**.

### Ring buffer maintenance

- Chunks are fixed-duration (default 30 s), written atomically (temp + rename) then indexed. On an interval flush, `fsync` **both the file and its directory**; on an encode failure, keep the partial chunk rather than discarding it.
- **Dual-rate storage:** each source keeps a native-rate listenable copy alongside the derived 16 kHz ASR feed — see [data formats](../data-formats.md#dual-rate-audio-storage).
- Eviction: on each new chunk, delete chunks whose end is older than `now - time_cap`; emit `evict`. If `hard_total_cap_bytes > 0`, evict oldest across sources until under budget.
- On startup after downtime, emit a `gap` event covering the uncaptured interval.

### VAD

- Pluggable backend (default Silero-class). Runs per source on the captured stream.
- Emits coarse `vad` spans (speech/silence) with padding/min-silence from config. This is an *index for skipping silence*, not a recording gate — all audio is still written.

### Lifecycle

- Runs as a launchd `LaunchAgent`; `KeepAlive` restarts on crash; `RunAtLoad` starts at login.
- Clean shutdown flushes the encode queue, closes chunks, and writes a final index flush. `SIGTERM` = graceful; `SIGKILL` recovery relies on atomic writes so at most the in-flight chunk is lost.
- **Power/idle awareness:** treat **system sleep, display sleep, and screen lock as independent suspension sources**, so (e.g.) a wake-while-locked stays suspended. Pause capture and any in-flight work on sleep and resume on wake, recording a `gap` for the suspended interval.
- **Login-item truth:** reconcile the configured launch-at-login preference against the real `SMAppService.status` and log/ surface mismatches rather than trusting the preference.
- Permissions handled per [Permissions and TCC probing](#permissions-and-tcc-probing) above.

### Footprint budget

- Idle (sources silent): negligible CPU beyond VAD; stable resident memory. Target a low, flat baseline with no growth over a multi-day run (no per-chunk leaks; bounded queues).
- Memory must not scale with buffer length on disk — the buffer is files, not RAM.

## Control socket protocol

> **Note:** a v2 control contract — id-correlated envelope, `hello` handshake, snapshot-on-subscribe, and a daemon-owned Meeting entity — is specified in [`control-protocol.md`](control-protocol.md). It is designed but not yet implemented; this section describes the v1 wire as built, which v2 supersedes when it lands.

Unix domain socket, newline-delimited JSON. Each connection is either **request/response** or, after `subscribe`, an **event stream**.

### Request/response

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
| `capture.pause` / `capture.resume` | Pause/resume a source or all (records a `gap`). |
| `session.open` | Open a session: `{sources, slug, start?, vocab?}` → session id. |
| `session.close` | Close a session by id (sets `end`, state=closed). |
| `session.list` | Open/recent sessions. |
| `mark` | Convenience: retroactively define a range (e.g. "last 30m") as a session. |
| `ingest.open` / `ingest.close` | **Not usable here** — always fail clearly. Browser audio ingestion is a separate loopback WebSocket, not the Unix socket; see [Audio ingestion](#audio-ingestion) below. |
| `segment.publish` | Publish one finalised `segment` event onto the live feed: `{session, speaker, start, end, text}`, the same fields the event carries. Sent by a `transcribe --follow` process (see [Live feed](#live-feed-pubsub)). Notification only — the daemon persists nothing and validates nothing beyond the wire shape; the durable transcript is the publisher's on-disk file. |
| `flush` | Finalizes and indexes each enabled source's in-progress chunk, then opens a fresh one — not a bare fsync of an unindexed partial. |

### Audio ingestion

Browser-sourced (`browser:<label>`) audio does **not** flow over the Unix control socket above — it uses a separate **loopback WebSocket** ingest endpoint, `[earsd.ingest_ws]` (`ws://127.0.0.1:<port>/ingest`, off by default). The Unix socket's own `ingest.open`/`ingest.close` always fail clearly ("use the WebSocket ingest endpoint"): a page-driven browser extension has no way to reach a privileged Unix socket, and the daemon's control plane (`status`/`sources.*`/`session.*`) must stay off any endpoint a web page's `Origin` could otherwise reach.

- **Bind:** `127.0.0.1` only, never `0.0.0.0`/`::`. Serves exactly one path, `GET /ingest`; anything else gets `404`.
- **Origin allowlist:** the WebSocket upgrade validates the handshake's `Origin` header against `[earsd.ingest_ws].allowed_origins` *before* completing it — a disallowed origin (or, with an empty allowlist, *any* origin) gets `403` and no upgrade. Browsers set `Origin` truthfully on the handshake and page content cannot forge it, so this is what keeps a random web page from streaming audio in even though the port is open.
- **Wire protocol:** control is text frames, reusing the same `ControlRequest`/`ControlResponse` Codable types as the Unix socket — but **ingest-only**: only `ingest.open`/`ingest.close` are accepted; every other `cmd` (`subscribe` included) is rejected, so an allowed origin still cannot drive the daemon.

  ```jsonc
  // text frame --> declare a stream
  {"cmd":"ingest.open","source":"browser:meet:jane-a1b2","format":{"sample_rate":16000,"channels":1,"encoding":"pcm_s16le"}}
  // text frame <-- {"ok":true,"data":{"stream_id":"s7"}}

  // text frame --> end a stream
  {"cmd":"ingest.close","stream_id":"s7"}
  // text frame <-- {"ok":true,"data":{}}
  ```

  Audio is binary frames, one per PCM chunk, multiplexed by `stream_id` — no sequence number, since WebSocket rides TCP and frames are already ordered and reliable:

  ```
  [ u8 idLen ][ stream_id : idLen ASCII bytes ][ pcm_s16le bytes (mono, little-endian) ]
  ```

- **Source lifecycle:** a `browser:<label>` source is created lazily on its first-ever `ingest.open` — there is no `[[earsd.source]]` config entry to resolve one from ahead of time — and persists for the daemon's lifetime once seen. A later `ingest.open` for the same label (a participant leaving and rejoining a call) resumes the *same* on-disk source rather than fragmenting into a new one. Ingested audio is resampled/encoded and appended to it exactly like locally-captured audio; `ingest.close` flushes and indexes its in-progress chunk, the same as `sources.disable`.

Full client-side detail — the browser extension's connection lifecycle, reconnect/backoff, and back-pressure policy — lives in [`docs/product/browser/specs/transport.md`](../browser/specs/transport.md), which this endpoint matches wire-for-wire.

### Live feed (pub/sub)

```jsonc
// --> {"cmd":"subscribe","events":["vad","session","segment"],"sources":["mic","app:us.zoom.xos"]}
// <-- stream of events:
{"ev":"vad","source":"mic","state":"speech","t":"2026-07-17T10:30:02.14Z"}
{"ev":"session","id":"...standup","state":"open"}
{"ev":"segment","session":"...standup","speaker":"You","start":604.1,"end":611.9,"text":"..."}  // published by a streaming transcriber
```

`segment` events originate from a `transcribe --follow` process that publishes back to the daemon (the `segment.publish` command above), letting many consumers watch one live transcript. The socket is notification only: a subscriber that connects late gets no replay — the durable transcript is the on-disk file.

## `ears` — control client

Thin CLI wrapper over the socket. One job: let a human or a trigger drive the daemon.

```
ears status
ears sources list
ears sources enable app:us.zoom.xos
ears session open --slug standup --source mic --source app:us.zoom.xos
ears session close <id>
ears mark --last 30m --slug hallway-chat        # retroactive session
ears watch --events vad,segment                 # subscribe and print the live feed
```

Every subcommand provides `--help` with concise argument descriptions. Output is human-readable by default, `--json` for scripting. Exits non-zero with a clear message if the daemon is unreachable.

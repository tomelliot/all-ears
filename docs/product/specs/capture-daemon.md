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
| `ingest.open` | Begin pushing audio for a `browser:<label>` source: declares format. |
| `flush` | Finalizes and indexes each enabled source's in-progress chunk, then opens a fresh one — not a bare fsync of an unindexed partial. |

### Audio ingestion

```jsonc
// --> declare a stream
{"cmd":"ingest.open","source":"browser:meet","format":{"sample_rate":48000,"channels":1,"encoding":"pcm_s16le"}}
// <-- {"ok":true,"data":{"stream_id":"s7"}}
// then binary/base64 frames are pushed referencing stream_id (framing defined in the wire spec)
```

Ingested audio is resampled/encoded and appended to the named source exactly like locally-captured audio.

### Live feed (pub/sub)

```jsonc
// --> {"cmd":"subscribe","events":["vad","session","segment"],"sources":["mic","app:us.zoom.xos"]}
// <-- stream of events:
{"ev":"vad","source":"mic","state":"speech","t":"2026-07-17T10:30:02.14Z"}
{"ev":"session","id":"...standup","state":"open"}
{"ev":"segment","session":"...standup","speaker":"You","start":604.1,"end":611.9,"text":"..."}  // published by a streaming transcriber
```

`segment` events originate from a `transcribe --follow` process that publishes back to the daemon, letting many consumers watch one live transcript.

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

# Architecture

## Overview

```
   audio sources                   earsd (daemon)              on-disk audio store
 ┌───────────────┐   Core Audio   ┌──────────────────┐  writes   ┌──────────────────────┐
 │ microphone    │──────────────▶ │  per-source      │─────────▶ │ <root>/meetings/<id>/│
 │ system audio  │──────────────▶ │  capture engines │           │   sources/<sid>/     │
 │ per-app audio │──────────────▶ │  + VAD           │           │     chunks/ asr/     │
 │ browser ext.  │──push (WS)───▶ │  (meeting-scoped)│           │ <root>/sessions/     │
 └───────────────┘                └────────┬─────────┘           └─────────┬────────────┘
                                           │ control socket                │ reads (files)
                                           │ (status, sessions,            ▼
                              ┌────────────┴───────┐         ┌──────────────────────────┐
                              │ ears / triggers    │         │ transcribe → cleanup →   │
                              │ (session lifecycle)│────────▶│ summarize                │
                              └────────────────────┘  invoke └─────────────┬────────────┘
                                                                           │ writes
                                                                           ▼
                                                             ┌──────────────────────────┐
                                                             │ <output>/YYYY-MM-DD/*.md │
                                                             └──────────────────────────┘
```

Four cooperating parts:

1. **`earsd`** — the always-running capture daemon. Boots idle and records only while a meeting is active: a meeting names its sources, capture starts, and everything recorded lands under that meeting's own directory. Owns the VAD index, session and meeting records, retention, and the control plane. It is the only writer to the audio store and is never in the read path.
2. **The audio store on disk** — the storage contract, one directory per meeting. Its documented layout *is* the read API. See [data formats](./data-formats.md).
3. **`ears` and trigger logic** — the control client, plus the daemon's app-signal triggers that open/close sessions and invoke the pipeline.
4. **The pipeline tools** — `transcribe`, `cleanup`, `summarize`. Independent binaries that read files (and, for streaming, tail the live index) and write Markdown outputs.

## The disk-as-API contract

The store's on-disk layout is a stable, documented interface. Any tool — and any future front-end — reads audio, the VAD index, and session metadata directly from files. Deliberate consequences:

- The daemon is not a bottleneck or single point of failure for reads. If `earsd` crashes, everything already captured stays readable and transcribable.
- Tools are developed and tested against a fixture audio store with no daemon running.
- `ls`, `cat`, `jq`, and `tail -f` are first-class debugging tools.

The daemon owns **writes** to the audio store. No other tool writes there. Pipeline tools write only to the configured output location.

## The control plane

`earsd` serves the same command set on two transports (see the [capture-daemon spec](./specs/capture-daemon.md) for the wire protocol):

- A **Unix domain socket** (default under the runtime dir) — the privileged plane the `ears` CLI and pipeline tools use. Newline-delimited JSON request/response, plus a subscribe mode streaming live events (VAD transitions, session/meeting changes, transcript segments).
- A **loopback control WebSocket** (`[earsd.control_ws]`, off by default) — the browser extension's route to the same commands, gated by a fail-closed `Origin` allowlist.

Audio ingestion is separate: the extension pushes binary PCM over a dedicated **loopback ingest WebSocket** (`[earsd.ingest_ws]`) that accepts nothing but `ingest.open`/`ingest.close` and audio frames. Results always land on disk; the sockets carry control and notifications only.

A redesigned contract (correlated requests, snapshot-on-subscribe, a daemon-owned meeting lifecycle) is specified in [control protocol v2](./specs/control-protocol.md) and not yet implemented.

## Sources

A **source** is an independently-captured audio stream with a stable id. Sources are kept fully separate end to end: separate audio directories, separate VAD indices, separate transcripts. Classes:

- `mic` — the default (or a named) input device.
- `system` — aggregate system output audio, via a Core Audio process tap.
- `app:<bundle-id>` — system audio scoped to one application (e.g. `app:us.zoom.xos`), via per-process tap inclusion lists.
- `browser:<platform>:<participant>` — per-participant meeting audio pushed in by the browser extension, created lazily on first ingest.
- `device:<uid>` — a specific external input device.

Keeping mic and system/app audio separate is what yields you-vs-them attribution for free; per-participant browser sources extend it to named speakers.

## Data flow

**Capture (meeting-scoped):** the daemon boots idle. When a meeting starts (browser extension, CLI, or trigger), the daemon starts capture of the meeting's sources; each engine appends encoded, time-stamped chunks — and its VAD appends speech/silence spans — under `meetings/<id>/sources/<sid>/`. When the meeting ends, capture stops and the actors are torn down.

**Retention (transcript-driven):** after a meeting ends and its transcript completes, the meeting's audio is kept `evict_after_transcript_seconds` (default 2 h), then the whole `sources/` directory is deleted in one pass. A meeting whose transcript never completed keeps its audio until `max_audio_age_seconds` (default 7 days) after it ended, so a failed transcription can be retried, then it too is deleted. `meeting.toml`, `events.jsonl`, and transcripts are never deleted.

**Sessions:** a trigger (app-signal, browser meeting, or manual) opens a session naming sources and a start time. Sessions are metadata over the recorded audio, not a separate recording. On close, the trigger's `on_close` list runs the pipeline over the session's range.

**Transcription and downstream:** `transcribe` resolves a source + range (or session) to chunks via the index, skips silence using VAD spans, runs the ASR model, and writes a transcript. `cleanup` corrects it with an LLM and the vocabulary list. `summarize` renders summaries from configured prompts. Each step is separately invokable and communicates only through files.

**Streaming:** `transcribe --follow <source>` tails a live source's index, decodes incrementally, emits finalised segments to stdout, appends to the transcript file, and republishes segments onto the daemon's live feed (`segment.publish`) for other subscribers. Batch and streaming produce the same on-disk format.

## Concurrency & runtime model

The core is **headless and actor-based** — a hard constraint, not a style preference:

- **No `@MainActor` anywhere in the core.** Engines, managers, and protocols are `actor`/`Sendable` boundaries, enforced by Swift 6 strict concurrency. The one valid exception is a realtime type where an actor would add latency; there, a lock plus `@unchecked Sendable` is acceptable, deliberately and locally.
- **Actor decomposition inside `earsd`:** one `CaptureActor` per source (its capture backend, chunk writer, and VAD), built when a meeting names the source and torn down when its last meeting ends; a `ControlServer` owning the control plane; and `SessionRegistry`/`MeetingRegistry` owning descriptors. Per-source actors isolate failures — one source's teardown never stalls another.
- **Generation counters guard every teardown.** Every IO-proc/tap callback is gated by a generation counter so a stale hardware callback from a torn-down engine cannot corrupt a new one after a device hot-swap. Any `await` in a capture path re-checks ownership before acting on the result.

### Two stores, kept distinct

There are two buffers in the capture path, and conflating them is a known bug source:

1. **The in-RAM jitter buffer** — a per-source, fixed-size, lock-free single-producer/single-consumer circular buffer. The real-time IO-proc is allocation-free and only publishes samples into it; a separate worker drains it for encoding and disk I/O. Under sustained backpressure it drops loud: a dropped-sample counter is logged, and after N consecutive drops the stream fails rather than growing unbounded. Milliseconds-to-seconds deep.
2. **The on-disk audio store** — each meeting's recorded chunks, bounded by the meeting's duration and deleted wholesale by transcript-driven retention. Files, not RAM.

## Module structure

One Swift package (`daemon/`), split so almost all logic is unit-testable without hardware:

- **`EarsCore`** — pure library, no I/O: VAD-index reading and range reconstruction, segment merging, streaming-delta emission, frontmatter serialisation, socket message types, config layering. Deterministic and tested in isolation.
- **Protocol seams at every hardware/model boundary:** `CaptureBackend`, `Transcriber`, `StreamingTranscriber`, `Diarizer`, `VAD`, `PermissionProviding`. Each has a mockable default; the [model interface](./specs/model-interface.md) specifies the ASR/diarization ones.
- **Thin shims behind those protocols:** `EarsCaptureKit` (Core Audio, process taps), `EarsTranscribeKit` (FluidAudio/Parakeet), `EarsDataStore` (chunk I/O), `EarsIPC` (sockets, WebSocket servers), `EarsLLMKit` (LLM subprocess), plus `EarsConfig`, `EarsLogging`, `EarsCLISupport`, and `EarsDaemonKit` (daemon wiring).
- **Executables** (`earsd`, `ears`, `transcribe`, `cleanup`, `summarize`) are small — they wire libraries together and own no business logic.

## Failure and robustness

- **Daemon crash:** captured data remains readable; on restart a `gap` event covers the downtime.
- **Disk pressure:** audio accrues only while meetings are active, and transcript-driven retention deletes each meeting's audio shortly after its transcript lands (hard-capped at `max_audio_age_seconds` for failed runs); every deletion is logged.
- **Model/LLM failure:** pipeline stages fail loud with non-zero exits; outputs are written atomically (temp + rename) so a failed run never corrupts a good transcript.
- **Backpressure on ingestion:** if a socket producer outruns the daemon, buffering is bounded and drops are logged rather than growing without limit.

# Architecture

## Overview

```
   audio sources                   earsd (daemon)                 on-disk ring buffer
 ┌───────────────┐   Core Audio   ┌──────────────────┐  writes   ┌────────────────────┐
 │ microphone    │──────────────▶ │  per-source      │─────────▶ │ <root>/sources/<id>/│
 │ system audio  │──────────────▶ │  capture engines │           │   audio chunks      │
 │ per-app audio │──────────────▶ │  + VAD           │           │   index.jsonl       │
 │ browser plugin│──push (socket)▶│                  │           │   sessions/         │
 └───────────────┘                └────────┬─────────┘           └─────────┬──────────┘
                                           │ control socket                 │ reads (files)
                                           │ (status, sessions,             │
                                           │  ingest, live feed)            ▼
                              ┌────────────┴───────┐         ┌──────────────────────────┐
                              │ ears / triggers    │         │ transcribe → cleanup →    │
                              │ (session lifecycle)│────────▶│ summarize                 │
                              └────────────────────┘  invoke └─────────────┬────────────┘
                                                                            │ writes
                                                                            ▼
                                                              ┌──────────────────────────┐
                                                              │ <output>/YYYY-MM-DD/*.md  │
                                                              └──────────────────────────┘
```

The system is four cooperating parts:

1. **`earsd`** — the always-running capture daemon. Owns every audio source, writes the ring buffer, maintains the VAD index and session records, and exposes a control socket. It is the only writer to the ring buffer and is never in the read path.
2. **The ring buffer on disk** — the storage contract. Its documented layout *is* the read API. See [data formats](./data-formats.md).
3. **`ears` and trigger logic** — the control client and the auto-trigger mechanism that opens/closes sessions and invokes the pipeline.
4. **The pipeline tools** — `transcribe`, `cleanup`, `summarize`. Independent binaries that read files (and, for streaming, subscribe to the live feed), and write Markdown outputs.

## The disk-as-API contract

The ring buffer's on-disk layout is a stable, documented interface. Any tool — and any future front-end — reads audio, the VAD index, and session metadata directly from files. This has consequences that are deliberate design choices:

- The daemon is **not** a bottleneck or single point of failure for reads. If `earsd` crashes, everything already captured is still fully readable and transcribable.
- Tools can be developed and tested against a fixture ring buffer with no daemon running.
- `ls`, `cat`, `jq`, and `tail -f` are first-class debugging tools.

The daemon owns **writes** to the ring buffer. No other tool writes there. Pipeline tools write only to the configured output location.

## The control socket

`earsd` listens on a Unix domain socket (path configurable; default under the runtime dir). It carries three kinds of traffic and nothing that belongs on disk:

- **Control & query** — status, list/enable/disable sources, session lifecycle, pause/resume capture, rotate/flush.
- **Audio ingestion** — external producers (the browser plugin, future sources) push audio frames for a named source. Ingested audio joins that source's ring buffer exactly like a locally-captured one.
- **Live feed (pub/sub)** — subscribers receive events: VAD state changes, session open/close, and, when a streaming transcriber is attached, finalised transcript segments. This is how a future menu-bar app or the browser plugin UI watches live activity.

The protocol is newline-delimited JSON request/response with an event-stream mode for subscribers. It is specified in the [capture-daemon spec](./specs/capture-daemon.md). The socket is for control and ingestion only — results always land on disk.

## Sources

A **source** is an independently-captured audio stream with a stable id. Sources are kept fully separate end to end: separate ring buffers, separate VAD indices, separate transcripts. Source classes in scope:

- `mic` — the default input device (or a named input device).
- `system` — aggregate system output audio (what the Mac plays), via a Core Audio process tap.
- `app:<bundle-id>` — system audio filtered to a single application (e.g. `app:us.zoom.xos`), via per-process Core Audio taps.
- `browser:<label>` — audio pushed in over the control socket by the browser plugin.
- `device:<uid>` — a specific external input device.

Keeping mic and system/app audio separate is what yields **you-vs-them** attribution for free; diarization refines *who* within a stream. See [data formats](./data-formats.md#speaker-attribution).

## Data flow

### Capture (always on)
1. `earsd` opens each enabled source's capture engine.
2. Incoming audio is encoded and appended to that source's ring buffer as time-stamped chunks.
3. A cheap VAD runs per source; speech/silence transitions are appended to the source's `index.jsonl`.
4. Old chunks beyond the source's time cap are deleted. The buffer is bounded at all times.

### Sessions (meeting notes)
1. A trigger (app-signal or manual) tells `earsd` to open a session naming one or more sources and a start time.
2. `earsd` records a session descriptor referencing the live time range; capture itself is unchanged (sessions are metadata over the ring buffer, not a separate recording).
3. On close, the trigger invokes the pipeline for the session's range.

### Transcription and downstream (on demand / triggered)
1. `transcribe` is given a source + time range (or a session id). It reads the relevant chunks and VAD index, skips silence, runs the ASR model, optionally diarizes, and writes a transcript to the output location.
2. `cleanup` reads that transcript, applies the LLM with the known-word list and context, and writes a cleaned transcript.
3. `summarize` reads one or more transcripts and writes summaries from configured prompts.

Each step is separately invokable and communicates only through files. A trigger simply chains them; a user can run any one alone.

### Streaming
`transcribe --follow <source>` attaches to a live source: it reads newly-written chunks as they land, emits finalised segments to stdout, appends to the session transcript file, and publishes segments to the control socket's live feed. Batch and streaming produce the same on-disk transcript format.

## Process and lifecycle

- `earsd` runs as a user-level background service (launchd `LaunchAgent`). It survives logout/login per launchd policy and restarts on crash.
- Pipeline tools are short-lived processes invoked per task (by the user or by a trigger). They hold no long-running state.
- Triggers are lightweight: a small launchd/event mechanism that watches for app-signal conditions and calls `ears`/the pipeline. Trigger rules are configuration, not code.

## Concurrency & runtime model

The core is **headless and actor-based**. This is a hard constraint, not a style preference: the strongest reference codebases converge on it, and the one portable mistake in an otherwise-exemplary one (pindrop's `@MainActor` ASR protocol) is exactly what a background daemon must not copy.

- **No `@MainActor` anywhere in the core.** `earsd` and the pipeline tools have no UI affinity. Engines, managers, and protocols are `actor`/`Sendable` boundaries, `Sendable` enforced throughout (Swift 6 strict concurrency). The valid low-level exception is a realtime type where a custom actor would add latency — there, a lock (`Mutex`) + `@unchecked Sendable` is acceptable, deliberately and locally.
- **Actor decomposition inside `earsd`:** one `CaptureActor` per source (owns its capture backend, ring writer, and VAD), a `ControlServer` actor owning the Unix socket, and a `SessionStore` actor owning session descriptors. Each source is independent, so per-source actors isolate failures and let one source's teardown never stall another.
- **Generation counters guard every teardown.** Every IO-proc / tap callback is gated by a generation counter (or a lock-free atomic gate) so a stale hardware callback from a torn-down engine cannot corrupt a new session after a device hot-swap. This is the most-repeated real-time correctness pattern in the survey; it is built into `CaptureActor` from the start, and any `await` in a capture path re-checks ownership before acting on the result.

### Two buffers, kept distinct

There are **two** buffers in the capture path and conflating them is a known bug source (flagged in the survey):

1. **The in-RAM jitter buffer** — a per-source, fixed-size, **lock-free single-producer/single-consumer (SPSC) ring**. The real-time IO-proc is allocation-free and only publishes samples into this ring; a separate `userInteractive` worker drains it to do encoding and disk I/O. Under sustained backpressure it **drops loud**: a dropped-sample counter is surfaced in logs, and after N consecutive drops the stream fails rather than growing unbounded. This buffer is milliseconds-to-seconds deep.
2. **The on-disk ring buffer** — the bounded, time-capped (default 2 h) retroactive store described above. This is files, not RAM.

The RAM ring is the realtime hand-off; the disk ring is the retroactive history. They are never the same allocation.

## Module structure

The suite is a Swift Package Manager workspace, not a single target. The survey's top codebases are all idiomatic but docked for monolithic god-files and single-target sprawl; our one-job-per-tool split is the fix **only if we also hold internal module boundaries**.

- **`EarsCore` (pure library, no I/O):** ring-buffer/time-cap math, VAD-index reading and range reconstruction, segment/word-timing merging, streaming-delta emission, frontmatter serialisation, config layering. Everything here is deterministic and unit-tested in isolation (see [engineering practices](./engineering-practices.md)).
- **Protocol seams at every hardware/model boundary.** Each is a protocol with a mockable default: `CaptureBackend` (mic / system / app / device / ingest), `Transcriber`, `Diarizer`, `VAD`, and `PermissionProviding`. This is the single strongest maintainability signal in the corpus and what makes the shims testable. The `Transcriber`/`Diarizer` protocols are specified in the [model interface](./specs/model-interface.md).
- **Thin shims over `EarsCore`.** Core Audio, Core ML/ANE, and process-tap code are kept as thin as possible behind their protocols, so almost no logic escapes unit coverage.
- **Executables** (`earsd`, `ears`, `transcribe`, `cleanup`, `summarize`) are small — they wire `EarsCore` + shims together and own no business logic.

## Failure and robustness

- **Daemon crash:** captured data remains readable; launchd restarts the daemon; capture resumes. A gap is recorded in the index for the downtime.
- **Disk pressure:** the time cap bounds the buffer; the daemon also honours a hard total-size ceiling as a backstop and logs when it evicts.
- **Model/LLM failure:** pipeline stages fail loud with clear errors and non-zero exit; partial outputs are written atomically (temp file + rename) so a failed run never corrupts a good transcript.
- **Backpressure on ingestion:** if a socket producer outruns the daemon, the daemon applies bounded buffering and logs drops rather than growing without limit.

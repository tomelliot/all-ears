# Architecture

## Overview

```
   audio sources                   earsd (daemon)                 on-disk ring buffer
 ┌───────────────┐   Core Audio   ┌──────────────────┐  writes   ┌─────────────────────┐
 │ microphone    │──────────────▶ │  per-source      │─────────▶ │ <root>/sources/<id>/│
 │ system audio  │──────────────▶ │  capture engines │           │   chunks/ asr/      │
 │ per-app audio │──────────────▶ │  + VAD           │           │   index.jsonl       │
 │ browser ext.  │──push (WS)───▶ │                  │           │ <root>/sessions/    │
 └───────────────┘                └────────┬─────────┘           └─────────┬───────────┘
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

1. **`earsd`** — the always-running capture daemon. Owns every audio source, writes the ring buffer, maintains the VAD index, session and meeting records, and exposes the control plane. It is the only writer to the ring buffer and is never in the read path.
2. **The ring buffer on disk** — the storage contract. Its documented layout *is* the read API. See [data formats](./data-formats.md).
3. **`ears` and trigger logic** — the control client, plus the daemon's app-signal triggers that open/close sessions and invoke the pipeline.
4. **The pipeline tools** — `transcribe`, `cleanup`, `summarize`. Independent binaries that read files (and, for streaming, tail the live index) and write Markdown outputs.

## The disk-as-API contract

The ring buffer's on-disk layout is a stable, documented interface. Any tool — and any future front-end — reads audio, the VAD index, and session metadata directly from files. Deliberate consequences:

- The daemon is not a bottleneck or single point of failure for reads. If `earsd` crashes, everything already captured stays readable and transcribable.
- Tools are developed and tested against a fixture ring buffer with no daemon running.
- `ls`, `cat`, `jq`, and `tail -f` are first-class debugging tools.

The daemon owns **writes** to the ring buffer. No other tool writes there. Pipeline tools write only to the configured output location.

## The control plane

`earsd` serves the same command set on two transports (see the [capture-daemon spec](./specs/capture-daemon.md) for the wire protocol):

- A **Unix domain socket** (default under the runtime dir) — the privileged plane the `ears` CLI and pipeline tools use. Newline-delimited JSON request/response, plus a subscribe mode streaming live events (VAD transitions, session/meeting changes, transcript segments).
- A **loopback control WebSocket** (`[earsd.control_ws]`, off by default) — the browser extension's route to the same commands, gated by a fail-closed `Origin` allowlist.

Audio ingestion is separate: the extension pushes binary PCM over a dedicated **loopback ingest WebSocket** (`[earsd.ingest_ws]`) that accepts nothing but `ingest.open`/`ingest.close` and audio frames. Results always land on disk; the sockets carry control and notifications only.

A redesigned contract (correlated requests, snapshot-on-subscribe, a daemon-owned meeting lifecycle) is specified in [control protocol v2](./specs/control-protocol.md) and not yet implemented.

## Sources

A **source** is an independently-captured audio stream with a stable id. Sources are kept fully separate end to end: separate ring buffers, separate VAD indices, separate transcripts. Classes:

- `mic` — the default (or a named) input device.
- `system` — aggregate system output audio, via a Core Audio process tap.
- `app:<bundle-id>` — system audio scoped to one application (e.g. `app:us.zoom.xos`), via per-process tap inclusion lists.
- `browser:<platform>:<participant>` — per-participant meeting audio pushed in by the browser extension, created lazily on first ingest.
- `device:<uid>` — a specific external input device.

Keeping mic and system/app audio separate is what yields you-vs-them attribution for free; per-participant browser sources extend it to named speakers.

## Data flow

**Capture (always on):** each enabled source's engine appends encoded, time-stamped chunks to its ring buffer; a per-source VAD appends speech/silence spans to `index.jsonl`; chunks beyond the time cap are evicted. The buffer is bounded at all times.

**Sessions:** a trigger (app-signal, browser meeting, or manual) opens a session naming sources and a start time. Sessions are metadata over the ring buffer, not a separate recording. On close, the trigger's `on_close` list runs the pipeline over the session's range.

**Transcription and downstream:** `transcribe` resolves a source + range (or session) to chunks via the index, skips silence using VAD spans, runs the ASR model, and writes a transcript. `cleanup` corrects it with an LLM and the vocabulary list. `summarize` renders summaries from configured prompts. Each step is separately invokable and communicates only through files.

**Streaming:** `transcribe --follow <source>` tails a live source's index, decodes incrementally, emits finalised segments to stdout, appends to the transcript file, and republishes segments onto the daemon's live feed (`segment.publish`) for other subscribers. Batch and streaming produce the same on-disk format.

## Concurrency & runtime model

The core is **headless and actor-based** — a hard constraint, not a style preference:

- **No `@MainActor` anywhere in the core.** Engines, managers, and protocols are `actor`/`Sendable` boundaries, enforced by Swift 6 strict concurrency. The one valid exception is a realtime type where an actor would add latency; there, a lock plus `@unchecked Sendable` is acceptable, deliberately and locally.
- **Actor decomposition inside `earsd`:** one `CaptureActor` per source (its capture backend, ring writer, and VAD), a `ControlServer` owning the control plane, and `SessionRegistry`/`MeetingRegistry` owning descriptors. Per-source actors isolate failures — one source's teardown never stalls another.
- **Generation counters guard every teardown.** Every IO-proc/tap callback is gated by a generation counter so a stale hardware callback from a torn-down engine cannot corrupt a new one after a device hot-swap. Any `await` in a capture path re-checks ownership before acting on the result.

### Two buffers, kept distinct

There are two buffers in the capture path, and conflating them is a known bug source:

1. **The in-RAM jitter buffer** — a per-source, fixed-size, lock-free single-producer/single-consumer ring. The real-time IO-proc is allocation-free and only publishes samples into it; a separate worker drains it for encoding and disk I/O. Under sustained backpressure it drops loud: a dropped-sample counter is logged, and after N consecutive drops the stream fails rather than growing unbounded. Milliseconds-to-seconds deep.
2. **The on-disk ring buffer** — the bounded, time-capped retroactive store. Files, not RAM.

## Module structure

One Swift package (`daemon/`), split so almost all logic is unit-testable without hardware:

- **`EarsCore`** — pure library, no I/O: ring-buffer/time-cap math, VAD-index reading and range reconstruction, segment merging, streaming-delta emission, frontmatter serialisation, socket message types, config layering. Deterministic and tested in isolation.
- **Protocol seams at every hardware/model boundary:** `CaptureBackend`, `Transcriber`, `StreamingTranscriber`, `Diarizer`, `VAD`, `PermissionProviding`. Each has a mockable default; the [model interface](./specs/model-interface.md) specifies the ASR/diarization ones.
- **Thin shims behind those protocols:** `EarsCaptureKit` (Core Audio, process taps), `EarsTranscribeKit` (FluidAudio/Parakeet), `EarsDataStore` (chunk I/O), `EarsIPC` (sockets, WebSocket servers), `EarsLLMKit` (LLM subprocess), plus `EarsConfig`, `EarsLogging`, `EarsCLISupport`, and `EarsDaemonKit` (daemon wiring).
- **Executables** (`earsd`, `ears`, `transcribe`, `cleanup`, `summarize`) are small — they wire libraries together and own no business logic.

## Failure and robustness

- **Daemon crash:** captured data remains readable; on restart a `gap` event covers the downtime.
- **Disk pressure:** the time cap bounds the buffer; a hard total-size ceiling (`hard_total_cap_bytes`) is the backstop, and eviction is logged.
- **Model/LLM failure:** pipeline stages fail loud with non-zero exits; outputs are written atomically (temp + rename) so a failed run never corrupts a good transcript.
- **Backpressure on ingestion:** if a socket producer outruns the daemon, buffering is bounded and drops are logged rather than growing without limit.

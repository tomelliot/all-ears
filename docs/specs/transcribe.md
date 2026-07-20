# Spec: `transcribe`

## One job

Turn ring-buffer audio for a source + time range (or a session) into a transcript on disk. Batch or streaming. Reads files directly; does not depend on `earsd` running except to publish live-feed events in `--follow` mode.

## Inputs

- A **source** (`--source mic`, repeatable) and a **time range** (`--last 30m`, or `--from`/`--to`), **or** a **session** (`--session <id>`, which resolves sources, range, pre-roll widening, and vocabulary from the descriptor).
- An output override (`--out`); otherwise the [output layout](../data-formats.md#directory-layout) decides.

The ASR backend is currently fixed: Parakeet via FluidAudio on the Apple Neural Engine.

## Behaviour (batch)

1. Resolve the requested range to chunks via each source's `index.jsonl`; honour `gap` events as known-missing (logged, not fatal).
2. Use `vad` spans to feed only speech to the model, preserving true timestamps across skipped gaps.
3. **Segment at natural pauses, not fixed cuts:** audio is grouped into model inputs bounded by VAD silence, with a short pre-roll before each utterance onset so the first word isn't clipped. (Storage chunks stay fixed-length; this segmentation is a transcription-time concern.)
4. Run the ASR backend, producing timed segments with word timings/confidence where available.
5. Merge sources onto a shared timeline, each segment tagged with its source and speaker label (`mic` → `You`, other sources → the source id; within-stream diarization is not yet implemented).
6. Write the transcript Markdown (and JSON sidecar) atomically per the [transcript format](../data-formats.md#transcript-format).

Multiple sources are transcribed independently, then merged for output — keeping sources separate through the model is what preserves you-vs-them attribution.

## Streaming mode (`--follow <source>`)

- Tails the live source's index, reading newly-written chunks as they land.
- Emits finalised segments to stdout as they stabilise (one per line; `--json` for JSON segment lines).
- Appends to the session's transcript file — the same file batch mode would produce, so the file is complete when the session closes.
- Publishes `segment` events to the daemon's live feed via `segment.publish`, letting other subscribers watch one live transcript. The socket is notification-only; the durable transcript is the file.
- Uses a real `StreamingTranscriber` (Parakeet TDT decoder state threaded between steps) — it does not fake streaming by re-transcribing overlapping windows and de-duplicating.

### Append-only delta contract

Streaming output must be safe for a no-backspace sink (a terminal, the socket feed, an appended file):

- Output is an **append-only stream of deltas**; the emitted cursor never moves backward. Once text is emitted it is never retracted.
- **Hold back a trailing incomplete unit** (trailing U+FFFD / partial token) until the next step confirms it, so a consumer never sees a garbled tail.
- Decouple chunk-arrival cadence from model step size with a fixed-cadence batcher.
- **Two-pass finalization:** cheap low-latency partials, then one max-look-ahead re-decode before text is committed to disk. Partials may change; committed text does not.

The delta logic is pure and lives in `EarsCore`, covered by tier-0 tests.

## Vocabulary

A session's vocabulary (global + per-session lists) is resolved with the session and recorded in the transcript frontmatter so `cleanup` can use it as a correction backstop. Decoder-level biasing (the `BiasingTranscriber` capability in the [model interface](./model-interface.md)) is designed but not implemented by the Parakeet backend yet.

## CLI

```
transcribe --last 20m --source mic
transcribe --from 2026-07-17T10:30:00Z --to 2026-07-17T11:02:00Z --source mic --source app:us.zoom.xos
transcribe --session 2026-07-17T10-30-00Z_standup
transcribe --follow mic --json | my-live-ui

Options:
  --source <id>            source(s) to transcribe; repeatable
  --last <dur>             range ending now (e.g. 30m, 2h)
  --from/--to <ts>         explicit ISO-8601 range
  --session <id>           resolve range, sources, and vocab from a session
  --follow <id>            attach to a live source and stream finalised segments
  --json                   (follow) emit JSON segment lines to stdout
  --out <path>             override the output transcript path
  --config / --print-config / --config-path / --log-level / --log-file
```

Exits non-zero with a precise error if the range is empty or invalid, sources are unknown, or the model fails; output is never left half-written (atomic rename).

## Outputs

- `<output-root>/<date>/<time>_<slug|range>.transcript.md` — canonical human transcript.
- `.transcript.json` sidecar with word-level detail.
- A final `run.summary` log record: segments, words, speech seconds, wall time, real-time factor, output path.

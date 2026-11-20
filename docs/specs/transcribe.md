# Spec: `transcribe`

## One job

Turn captured audio for a session (or a source + time range) into a transcript on disk. Batch or streaming. Reads files directly; does not depend on `earsd` running except to publish live-feed events in `--follow` mode.

The transcript it writes is an **intermediate**, not a deliverable: it lands in the data store, addressed by session or run id, and never under `output_root`. Publishing — a cleaned transcript at a user-configured path — is [`cleanup`](llm-stages.md)'s job.

## Inputs

- A **session** (`--session <uuid>`, which resolves sources, interval ranges, and optional vocabulary — `vocab/<id>.txt` — from the session record), **or** a **source** (`--source mic`, repeatable) and a **time range** (`--last 30m`, or `--from`/`--to`), **or** a **standalone file** (`--file memo.m4a`, repeatable) transcribed directly with no capture store involved. The selectors are mutually exclusive; mixing them is a hard error.
- An output override (`--out`); otherwise the [store layout](../data-formats.md#directory-layout) decides — except `--file`, which writes each transcript next to its input (`--out` applies only to a single `--file`).

The ASR backend is currently fixed: Parakeet via FluidAudio on the Apple Neural Engine.

## Behaviour (batch)

1. Resolve the requested range to chunks via each source's `index.jsonl`; honour `gap` events as known-missing (logged, not fatal). A chunk file that won't open/decode (e.g. an `.m4a` `ExtAudioFileOpenURL` refuses) is skipped and logged per-chunk (`chunk.unreadable: source=… file=… error=…`), degrading only its own span — the surrounding chunks still transcribe, rather than one unreadable file aborting the whole run.
2. Use `vad` spans to feed only speech to the model, preserving true timestamps across skipped gaps.
3. **Segment at natural pauses, not fixed cuts:** audio is grouped into model inputs bounded by VAD silence, with a short pre-roll before each utterance onset so the first word isn't clipped. (Storage chunks stay fixed-length; this segmentation is a transcription-time concern.)
4. Run the ASR backend, producing timed segments with word timings/confidence where available.
5. Merge sources onto a shared timeline, each segment tagged with its source and speaker label (`mic` → `You`, other sources → the source id). With `[diarize].backend = "sortformer"`, a multi-speaker far-end source (`system`/`app:*`/`device:*`) is additionally refined within-stream into `<source> · Speaker N` by an offline Sortformer pass; the `mic` and per-participant `browser:*` streams are single-speaker and left as-is. Overlapping speech is interleaved at **word** granularity: where one speaker's words begin during another's segment, the longer segment is split at that word boundary so the reply lands at its own timestamp rather than after the whole turn. Single-speaker runs are never split (a single-source transcript is byte-identical to ordering by segment start alone), and segments without word timings fall back to segment-start ordering. Because turns are grouped by the *resolved* speaker label, sources that resolve to the same name — e.g. one participant across a Meet identity upgrade, linked through the session's attendee roster — coalesce under one consistent label. Before the merge, a `browser:*` source that repeats the mic is left out: it is the user's own outgoing audio, captured a second time. A source qualifies when it carries at least 70% of the mic's words at about the same time (at least 100 mic words compared); the last speech-carrying `browser:*` source is never left out. When the richest such copy carries at least 1.25 times the mic's words over the span it covers, that copy replaces the mic there instead: it is labelled `You` and the mic's turns inside the span are left out. The transcript's `warnings` record how many sources were left out and whether the mic was replaced, and the session's speaker map is re-derived without them.
6. Write the transcript Markdown (and JSON sidecar) atomically per the [transcript format](../data-formats.md#transcript-format).
7. Print the result: in default mode, stdout is exactly one line — the written transcript's absolute path, nothing else — per the frozen [output-path contract](llm-stages.md#output-path-contract-stdout). With `--json`, stdout is exactly one result-envelope document instead (`allears.transcribe/v1`); the daemon's session-end pipeline invokes this mode. `--json`'s batch meaning is distinct from its `--follow` meaning (JSON segment lines) — the modes are mutually exclusive, so the two never collide in one run. Failure ⇒ empty stdout in both modes.

Multiple sources are transcribed independently, then merged for output — keeping sources separate through the model is what preserves you-vs-them attribution.

## Session mode (`--session <uuid>`)

`--session <uuid>` transcribes one daemon-owned session: it reads `session.toml`, unions the session's transcription intervals into the read range (paused spans are skipped exactly like silence), and takes the session's own source list and roster (so real participant names flow straight into speaker labels). This is the mode the daemon's session-end pipeline invokes.

**Per-source store lookup order.** A session's audio can live in two places, and `--session` resolves each source independently:

- the **per-session copy** under `sessions/<id>/sources/<source>/` — where session-scoped capture writes, and the authoritative copy for an ended session;
- the **legacy global ring** under `<data-root>/sources/<source>/` — never written by live capture any more, consulted only as a read fallback for a source with no per-session directory.

The rule: **prefer the per-session copy when it holds chunks in range, and fall back to the ring only where it doesn't** (all-ears issue #20). A source found in neither store contributes nothing — it does **not** fail the whole session, so the other sources still transcribe.

**Diagnosability.** Every store consulted is logged per source (its path and what it held — chunk count and speech-interval count, or "no data"), the chosen store is logged, and a run that ends with `segments=0` logs a one-line reason per source (`no chunks in range`, `chunks but no speech intervals`, or `store missing`). The chosen store per source is also recorded in the transcript's `audio_stores` frontmatter, so a wrong-store read is visible after the fact.

## Streaming mode (`--follow <source>`)

- Resolves the source through the session currently capturing it (live capture is session-scoped: audio lands under `sessions/<id>/sources/<source>/`), picking the most recently started non-ended session when several claim the source. No live session, or a claimed source with no data on disk, is a fail-fast error — never a silent attach to a dead index.
- Tails the live source's index, reading newly-written chunks as they land.
- Emits finalised segments to stdout as they stabilise (one per line; `--json` for JSON segment lines).
- Appends to a per-source live transcript inside the session's directory (`sessions/<id>/<source>.follow.transcript.md`) — the same renderers and format batch mode produces, kept under its own name so a follow run and the session's authoritative batch transcript never overwrite one another.
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

A session's optional vocabulary (`vocab/<session-id>.txt`, relative to the data root) is merged into the run's biasing context. Decoder-level biasing (the `BiasingTranscriber` capability in the [model interface](./model-interface.md)) is designed but not implemented by the Parakeet backend yet.

## CLI

```
transcribe --last 20m --source mic
transcribe --from 2026-07-17T10:30:00Z --to 2026-07-17T11:02:00Z --source mic --source app:us.zoom.xos
transcribe --session 0d5e7f6a-…
transcribe --follow mic --json | my-live-ui

Options:
  --source <id>            source(s) to transcribe; repeatable
  --last <dur>             range ending now (e.g. 30m, 2h)
  --from/--to <ts>         explicit ISO-8601 range
  --session <uuid>         union a session's intervals into one transcript
                           (per-source store lookup: per-session copy, ring fallback)
  --follow <id>            attach to a live source and stream finalised segments
  --json                   follow: emit JSON segment lines to stdout
                           batch: emit the one-document result envelope
                           (see llm-stages.md "Result envelopes"); the two
                           modes are mutually exclusive, so the flag is
                           unambiguous in every run
  --file <path>            transcribe a standalone audio file; repeatable, one
                           transcript per file, written next to its input
  --out <path>             override the output transcript path
  --config / --print-config / --config-path / --log-level / --log-file
```

Exits non-zero with a precise error if the range is empty or invalid, sources are unknown, or the model fails; output is never left half-written (atomic rename). Exit codes follow the shared taxonomy (0/3/4/5/64 — see [llm-stages.md "Exit codes"](llm-stages.md#exit-codes)), documented in `--help`.

## Outputs

All intermediates, in the data store — `output_root` is never consulted, so `run.start` never reports it and `run.summary` carries the real output path.

- `--session <uuid>` → `<data-root>/sessions/<uuid>/transcript.md`.
- `--last`/`--from`/`--to` → `<data-root>/runs/<start-timestamp>_<slug>.transcript.md`, keyed by the same identifier the transcript's `range_run:` frontmatter carries.
- `--follow <source>` → `<data-root>/sessions/<uuid>/<source>.follow.transcript.md`.
- `--file` → `<input-dir>/<name>.transcript.md`, beside the recording.
- `--out <path>` overrides any of these verbatim.
- A `.transcript.json` sidecar with word-level detail follows the Markdown in every case (same stem, `.md` → `.json`).
- A final `run.summary` log record: segments, words, speech seconds, wall time, real-time factor, output path.

The transcript's frontmatter carries `title:` (the session's display title) and `started:` (when the session began), so the publishing stage's path template resolves from the document rather than from flags — a manual rerun files exactly where the daemon-spawned run did.

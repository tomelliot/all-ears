# Spec: `transcribe`

## One job

Turn ring-buffer audio for a given source + time range (or a session) into a transcript on disk. Batch or streaming. Reads files directly; does not depend on `earsd` except for the live `--follow` mode.

## Inputs

- A **source** (`--source mic`) or **sources**, and a **time range** (`--from`/`--to`, or `--last 30m`), **or** a **session** (`--session <id>`, which resolves to its sources + range + vocabulary).
- Model/backend/compute selection (config or flags).
- Diarization on/off; vocabulary lists.

## Behaviour

1. Resolve the requested range to chunks via each source's `index.jsonl`; honour `gap` events as known-missing (logged, not fatal).
2. If `skip_silence`, use `vad` spans to feed only speech to the model, preserving true timestamps across skipped gaps.
3. **Segment at natural pauses, not fixed cuts.** Group audio into model inputs bounded by VAD silence (not arbitrary fixed-length slices that cut mid-sentence), and include a short **pre-roll** before each utterance onset so the first word isn't clipped. (Storage chunks stay fixed-length; this segmentation is a transcription-time concern.)
4. Decode chunks, run the ASR backend (default Parakeet via FluidAudio on the ANE), producing timed segments with word timings/confidence where available.
5. If diarization is enabled, run the diarization backend per multi-speaker source and assign stable `Speaker N` labels; `mic` maps to `You`.
6. Merge sources on a shared timeline, ordered by time, each segment tagged with its source and speaker.
7. Write the transcript Markdown (and optional `.transcript.json` sidecar) atomically to the output location, using the [transcript format](../data-formats.md#transcript-format).

Multiple sources are transcribed **independently** then merged for output; per-source transcripts remain reconstructable. Keeping sources separate through the model is what preserves you-vs-them.

## Streaming mode (`--follow`)

- Attaches to a live source: reads newly-indexed chunks as they land.
- Emits finalised segments to **stdout** (one per line, `--json` optional) as they stabilise.
- Appends to the session's transcript file (the same file batch mode would produce), so the file is complete when the session closes.
- Publishes `segment` events to the daemon's live feed for other subscribers. The socket is **notification only**; the durable transcript is the on-disk file.
- Requires a `StreamingTranscriber` backend (Parakeet TDT). It does **not** fake streaming by re-transcribing overlapping windows and de-duplicating — that wastes compute and is called out as an anti-pattern in the corpus.

### Append-only delta contract

Streaming output must be safe for a **no-backspace sink** (a terminal, our socket feed, a file being appended). The contract, taken from the cleanest reference (localvoxtral):

- Output is an **append-only stream of deltas**; the emitted cursor **never moves backward**. Once text is emitted it is never retracted.
- **Hold back a trailing incomplete unit** — specifically a trailing U+FFFD / partial multibyte or partial token — until the next step confirms it, so a consumer never sees a garbled tail.
- Decouple network/chunk cadence from model step size with a **fixed-cadence batcher** (localvoxtral's `StepBatcher`), tuned to the per-step compute budget.
- **Two-pass finalization:** emit cheap low-latency partials, then do one **max-look-ahead re-decode** for the committed text before it is finalised on disk. Partials may change; committed text does not.

This delta logic is pure and lives in `EarsCore`, unit-tested with tier-0 tests (see [engineering practices](../engineering-practices.md)).

## Known words

Vocabulary (global + session lists) is applied here as **model biasing** where the backend supports it (see [model interface](./model-interface.md)); the same list is also carried into the transcript frontmatter so `cleanup` can apply it as a backstop.

## CLI

```
transcribe --last 20m --source mic
transcribe --from 2026-07-17T10:30Z --to 2026-07-17T11:02Z --source mic --source app:us.zoom.xos
transcribe --session 2026-07-17T10-30-00Z_standup --diarize
transcribe --follow app:us.zoom.xos --json | my-live-ui

Options (excerpt):
  --source <id>            repeatable; source(s) to transcribe
  --last <dur>             range ending now (e.g. 30m, 2h)
  --from/--to <ts>         explicit ISO-8601 range
  --session <id>           resolve range+sources+vocab from a session
  --model <name>           override ASR model
  --backend <name>         fluidaudio | subprocess
  --compute <ane|gpu|cpu>
  --[no-]diarize
  --[no-]skip-silence
  --vocab <name|path>      additional vocabulary list(s)
  --out <path>             override output path
  --json                   (follow) emit JSON segments to stdout
```

`--help` gives concise descriptions of every argument. Exits non-zero with a precise error if the range is empty, sources are unknown, or the model fails; partial output is never left half-written (atomic rename).

## Outputs

- `<output-root>/<date>/<time>_<slug|range>.transcript.md` — canonical human transcript.
- Optional `.transcript.json` sidecar with word-level detail.
- A final log summary: segments, words, speech seconds, wall time, real-time factor, output path.

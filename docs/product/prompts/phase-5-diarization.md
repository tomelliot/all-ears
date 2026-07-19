# Prompt: diarization (Phase 5)

Use this prompt against the `all-ears` repo, `daemon/` Swift package. Per
`docs/roadmap.md`, this is the phase after multi-source capture + sessions
(Phase 4 — CATap system/per-app audio, app-signal triggers). It does **not**
strictly depend on Phase 4 landing first: diarization operates on whatever
audio `transcribe` already reads (today, just `mic` + `browser:<label>`), so
it can be built and DER-benchmarked against fixtures independently, then
automatically starts refining `app:`/`system` sources once Phase 4 makes them
real.

Confirmed still a stub: `EarsCore/Protocols/Diarizer.swift` is a real protocol
but has exactly one conformer, `EarsCoreTestSupport/NullDiarizer.swift`, whose
own doc comment says "proves the seam is mockable; not shipped capability."
`transcribe/TranscriptAssembly.swift` hardcodes
`TranscriptDiarizationInfo(enabled: false, backend: nil)` and labels every
segment by source id alone (`speakerLabel(for:)`). `transcribe`'s CLI
(`Transcribe.swift`) has no `--diarize`/`--no-diarize` flag at all yet.

---

## Task

Implement a real `Diarizer` backend, wire it into `transcribe` so multi-speaker
sources get `Speaker N` labels instead of a flat per-source label, add the
optional name-remap step to `cleanup`, and gate accuracy in CI with a DER
benchmark.

## Context (read first)

- `docs/specs/model-interface.md` §"Diarization backend protocol" — the
  authoritative spec for this phase. Load-bearing lines, not optional
  flavor text:
  - **"Channel-of-origin is the primary label; the diarizer only refines."**
    Source attribution (already implemented) never gets overridden — a
    diarizer that reassigns a `mic`-sourced segment to something other than
    `You`, or merges two sources' segments into one speaker, is a bug.
  - **Two-pass:** "a fast streaming pass attributes speakers live during
    `--follow`; an offline batch pass over the saved samples afterward
    stabilises the speaker IDs. The durable transcript reflects the
    stabilised pass." `--follow` is Phase 6, not yet built — implement the
    **offline batch pass** now (that's what batch `transcribe` needs and
    what this phase's exit bar is scored on); design `Diarizer`/
    `DiarizerInfo.supportsStreaming` so a live pass can be added in Phase 6
    without reshaping this protocol, but don't build the live half against
    a `--follow` mode that doesn't exist yet.
  - **Dominant-speaker filtering for `mic`:** optionally run diarization even
    on the single-speaker mic source and keep only the dominant speaker's
    spans, to reject background/overheard voices. **Off by default**
    (`mic` stays `You`).
  - **Anti-pattern, explicitly ruled out:** "faking diarization by
    concatenating mic + system transcripts and asking an LLM to guess
    speakers — that is not attribution." Do not build an LLM-based
    shortcut under any circumstance here.
  - Default backend is "a pyannote/sherpa-class model, via the subprocess
    path where needed" — see the same spec's §"Backend 2 — subprocess
    adapter" (shared with `Transcriber`) for the required discipline:
    `stdout` = JSON results, `stderr` = logs, strictly separated; **drain
    both pipes with a detached task before `waitUntilExit()`** (a filled
    64 KB pipe buffer deadlocks otherwise); pin model weights to exact
    Hugging Face commits.
- `daemon/Sources/EarsCore/Protocols/Diarizer.swift` +
  `Models/SpeakerSpan.swift` + `Models/DiarizerInfo.swift` — the exact seam
  to conform to: `diarize(_ audio: AudioBuffer) throws -> [SpeakerSpan]`,
  each span `{start, end, speaker}` in seconds relative to the diarized
  range's start (mirroring how `Segment.start`/`.end` are relative to the
  buffer a `Transcriber` decoded — see `TranscribePipeline.swift`'s
  `shifted(_:by:)` for the established pattern of shifting relative offsets
  onto the shared timeline before assembly).
- `daemon/Sources/transcribe/TranscriptAssembly.swift` — where labels are
  actually assigned today. `speakerLabel(for:)`'s doc comment already flags
  itself as "a defensible placeholder until per-speaker diarization exists."
  Replace the per-source flat label with: for a source with diarization
  spans, look up which span each segment's midpoint (or majority overlap)
  falls in and use that span's `speaker` label; for `mic` with dominant-
  speaker filtering enabled, drop segments not in the dominant span; for a
  source with no spans (diarization off, or a single-speaker source), keep
  today's `speakerLabel(for:)` behavior unchanged. Flip
  `TranscriptDiarizationInfo(enabled:, backend:)` to real values when a
  diarizer actually ran.
- `daemon/Sources/transcribe/TranscribePipeline.swift` — `Dependencies`
  currently only has `transcriberFactory`; add a `diarizerFactory: @Sendable
  () throws -> any Diarizer` (or `nil` when `--no-diarize`), mirroring how
  `transcriberFactory` is already structured, and thread the resulting
  `[SpeakerSpan]` per source into `TranscriptAssembly.assemble`. Note
  `Inputs` doesn't have a `diarize` field yet either — add one alongside the
  new CLI flag.
- `daemon/Sources/transcribe/Transcribe.swift` — add `--[no-]diarize` (spec's
  `docs/specs/transcribe.md` CLI section already documents this flag; it was
  simply never wired). Pre-existing gap, not this task's to fix: `--session`/
  `--from`/`--to`/`--vocab` are also documented in that spec but not yet
  implemented on this CLI (only `--last`/`--source`/`--out` exist) — don't
  silently assume they're there; add `--diarize` alongside what's real today.
- `docs/data-formats.md` §"Speaker attribution" — the `[speakers]` name-remap
  table (`"Speaker 2" = "Priya"`) lives in `session.toml` or a sidecar,
  "applied as a formatting concern at/after `cleanup`; it never mutates
  timings." `docs/specs/llm-stages.md` §4 (`cleanup`'s behaviour list):
  "Optionally apply a speaker name map (`Speaker 2` → real name) if present
  in the session." Confirmed unbuilt: `daemon/Sources/cleanup/Cleanup.swift`
  has no speaker-map handling at all, and
  `EarsCore/Models/SessionDescriptor.swift` has no `speakers` field —
  you'll need to add one (or a sidecar type, per data-formats.md's "in
  `session.toml` **or** a sidecar" wording — pick one and document why,
  same as this codebase's existing practice of resolving open ambiguity
  explicitly rather than leaving it implicit).
- `docs/engineering-practices.md` §"Benchmark-as-CI for the model path" —
  "Accuracy metrics (WER for ASR, DER for diarization...) are gated in CI
  against fixtures, so a ... bump can't silently regress quality." The
  transcription side already has this pattern (`4d900fd`'s benchmark-as-CI
  for Parakeet, referenced in the roadmap's Phase 2 exit bar) — mirror its
  shape for DER rather than inventing a new CI convention.

## Requirements

### 1. `Diarizer` conformance (subprocess adapter)

- New type (likely `EarsTranscribeKit`, alongside `ParakeetTranscriber`)
  wrapping a pyannote/sherpa-class subprocess per the shared subprocess
  contract: mono PCM/WAV in (stdin or temp file), JSON `[SpeakerSpan]`-shaped
  output on `stdout`, logs on `stderr`, both pipes drained by a detached task
  before `waitUntilExit()`.
- `DiarizerInfo.supportsStreaming = false` for this conformance — the live
  pass is Phase 6's job once `--follow` exists.
- Model weights pinned to an exact Hugging Face commit, include-pattern list
  kept in sync with the loader (same discipline as the ASR subprocess path,
  per the shared spec section).

### 2. Wire into `transcribe`

- `--[no-]diarize` flag on `Transcribe.swift`; threaded through
  `TranscribePipeline.Inputs`/`Dependencies` as described above.
- Per source, when diarization is on: run the diarizer over that source's
  full requested-range audio (not per natural-pause slice — the diarizer
  needs continuous context to assign stable IDs, unlike the ASR pass which
  already works slice-by-slice), producing spans relative to the range
  start; feed those spans into `TranscriptAssembly.assemble` for label
  resolution.
- Dominant-speaker filtering on `mic`: a separate, explicit opt-in (not
  implied by `--diarize` alone) — name it clearly in `--help` and default it
  off, per the spec.

### 3. Speaker name remapping in `cleanup`

- Add the `[speakers]` map to wherever you decide it should live
  (`session.toml` extension or sidecar) and read it in `cleanup`.
- Apply the rename as a **pure text substitution over already-produced
  labels** — never touch `start`/`end`/word timings, and never re-run or
  reinterpret the diarization itself. A label with no entry in the map is
  left as `Speaker N` unchanged.

### 4. DER benchmark-as-CI

- A fixture multi-speaker audio sample with ground-truth speaker spans (new
  test fixture — check `daemon/Tests/` for where the Parakeet WER/RTFx
  benchmark's fixtures live and mirror that layout).
- A CI-gated test computing DER between the real `Diarizer` conformance's
  output and ground truth, failing the build if DER regresses past a
  documented threshold — same shape as the existing Parakeet accuracy gate.

## Tests

- Tier 0: `TranscriptAssembly`'s span→label resolution is pure logic
  (segment-midpoint-or-overlap lookup against spans) — unit-test it directly
  with synthetic `SpeakerSpan`/`Segment` fixtures, no subprocess involved.
- Tier 2: the subprocess `Diarizer` conformance is behaviour-verified against
  the protocol mock in pipeline tests, and separately driven end-to-end
  against the real subprocess for the DER benchmark.
- Regression test proving channel-of-origin is never overridden: a `mic`
  segment stays `You` even when diarization is on and dominant-speaker
  filtering is off.
- `cleanup`'s speaker-remap: a fixture transcript with `Speaker 2`/`Speaker 3`
  labels and a `[speakers]` map produces the renamed output with identical
  timestamps — a regression test that timings are byte-for-byte unchanged is
  as important as the rename itself.

## Out of scope

- The live/streaming diarization pass (`--follow`-time attribution) — Phase 6.
- Per-app/system CATap capture — Phase 4; this phase's DER benchmark and
  correctness don't depend on it, since diarization operates on whatever
  audio is already captured.
- Adding `--session`/`--from`/`--to`/`--vocab` to `transcribe`'s CLI — a
  pre-existing gap noted above, not this task's to close. Add `--diarize`
  without blocking on it.
- Re-litigating vocabulary/known-word biasing — unrelated to diarization,
  already covered by Phase 3.

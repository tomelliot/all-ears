# Roadmap

Phased so each stage ships a usable, independently-valuable tool. Every phase carries the day-one requirements: structured logging, `--help`, atomic writes, config layering.

## Phase 0 — Foundations

- SPM workspace: the **`EarsCore` pure library** (ring-buffer/time-cap math, VAD-index reading, segment/word-timing merging, frontmatter serialisation, config layering) as its own target, tested in isolation.
- Shared config loader (TOML + env + flags) and **machine-first JSON Lines logging** with the `os.Logger` mirror.
- The **protocol seams** as empty-but-mockable interfaces: `CaptureBackend`, `Transcriber`, `Diarizer`, `VAD`, `PermissionProviding`.
- CI wired from the first commit: builds, runs the suite, enforces `.swift-format`.
- **Exit:** a fixture ring buffer can be created and read by `EarsCore`; config and logging work across a trivial binary; CI is green and gating.

## Phase 1 — Capture MVP (retroactive capture, mic only)

- `earsd` as a headless actor (`CaptureActor` + `ControlServer`): microphone capture → **dual-rate** compressed chunks (`chunks/` native + `asr/` 16 kHz) → `index.jsonl`, time-cap eviction, launchd agent.
- **Realtime hand-off** via the lock-free SPSC RAM ring with a dropped-sample counter; **generation-counter-guarded teardown** and default-device-change recovery (mic reconnect, live-`AudioBuffer` frame count).
- Per-source VAD writing spans to the index.
- Crash safety: atomic chunk writes, fsync file+dir, keep-partial-on-failure; **power/sleep handling** with gaps for suspended intervals.
- `ears status` and basic source commands over the socket.
- **Delivers UC-1 audio side:** the last 2 h of mic audio is always on disk, listenable, and inspectable.
- **Exit:** daemon runs for days at a flat memory baseline; buffer stays bounded; gaps recorded across restarts, sleep/wake, and device unplug.

## Phase 2 — Transcription MVP

- `transcribe` batch mode with the native Parakeet/FluidAudio backend behind the `Transcriber` protocol; silence-skipping and VAD-natural-pause segmentation via the index; mmap disk-backed audio reads.
- **FluidAudio/ANE hardening (non-optional):** ANE inference serialization (macOS 14 SIGBUS fix), SentencePiece word-timing reconstruction, trailing-silence pad, VAD on `.cpuOnly`, sandboxed model cache with resume/auto-recover.
- Markdown transcript output + optional JSON sidecar, written atomically.
- Global vocabulary as decoder biasing (`BiasingTranscriber`) where supported.
- **Benchmark-as-CI** for the Parakeet path (WER/RTFx) so a FluidAudio bump can't silently regress.
- **Delivers UC-1 fully:** `transcribe --last 20m --source mic` produces a saved transcript.
- **Exit:** faster-than-real-time transcription of a recent range on Apple Silicon; correct timestamps; accuracy benchmark gated in CI.

## Phase 3 — LLM stages

- `cleanup` and `summarize` on the `llm`-CLI backend behind the LLM interface; vocabulary as a cleanup backstop; summary presets.
- **Cleanup guardrails:** accept/fallback validator, skip-high-confidence-utterances, minimal-change prompt, stable-prefix/dynamic split for cache reuse.
- **Exit:** `transcribe → cleanup → summarize` runs end to end from the command line and produces clean notes + a summary; the validator demonstrably rejects a hallucinated cleanup on a fixture.
- The guardrail/validator pieces landed here first; the actual `cleanup`/`summarize` executables' CLI wiring (a real `command`-backend `LLMBackend`, a transcript reader, config schemas) landed alongside Phase 4, once that phase's auto-trigger pipeline needed them to be real.

## Phase 4 — Multi-source + sessions (meeting notes)

Executable prompt: [`prompts/phase-4-multi-source-sessions.md`](prompts/phase-4-multi-source-sessions.md) — landed, plus the Phase 3 CLI wiring gap it uncovered (see below).

- Core Audio process tap (`CATap` + private aggregate device) for **system audio**, then **per-app scoping** via the process-inclusion list — the least-proven path, so gated behind integration tests that verify inclusion/exclusion semantics. The recipe is verified against this machine's real Core Audio HAL (tap creation, format read, TCC-denial detection all confirmed live); per-app inclusion/exclusion isolation itself still needs its opt-in, manually-run integration test exercised on real hardware with a granted permission.
- **TCC probing** for the tap grant (create-and-destroy probe, all-zero-PCM detection, actionable "System Audio Recording Only" messaging); each source degrades independently on denial.
- Session lifecycle over the socket; app-signal auto-triggers running the pipeline on close (genuine audio-active correlation, not mere launch); prepend-on-open pre-roll from the ring (a `transcribe`-time-only widening — `session.toml`'s `start` is never rewritten).
- Source-level speaker attribution (you-vs-them) in transcripts (landed in Phase 3).
- **Also landed as part of this phase:** `cleanup`/`summarize` were still Phase-0 stubs and `transcribe` had no `--session`/`--from`/`--to` — all now real (a concrete `command`-backend `LLMBackend`, a transcript reader, validated `[llm]`/`[cleanup]`/`[[summarize.preset]]` config), since the auto-trigger's `on_close` pipeline needed them to produce an actual note.
- **Delivers UC-2:** a meeting produces an auto-generated cleaned, summarised note.
- **Exit:** starting a configured meeting app yields a filed note with no manual step; per-app capture isolates the meeting app from other system audio (integration-tested, opt-in on real hardware).

## Phase 5 — Diarization

Executable prompt: [`prompts/phase-5-diarization.md`](prompts/phase-5-diarization.md).

- Diarization behind the `Diarizer` protocol as an optional stage; **channel-of-origin as the primary label, diarizer refining the far-end**; two-pass (live attribution + offline batch to stabilise IDs); optional dominant-speaker filtering on the mic.
- Stable within-stream speaker labels; name remapping.
- **Benchmark-as-CI** for DER on a fixture.
- **Exit:** multi-speaker meeting audio is labelled per speaker with acceptable DER, gated in CI.

## Phase 6 — Streaming + browser ingestion

Executable prompt (remainder — browser ingestion already landed): [`prompts/phase-6-streaming-transcription.md`](prompts/phase-6-streaming-transcription.md).

- `transcribe --follow` on a `StreamingTranscriber`: the **append-only delta contract** (hold-back trailing U+FFFD, never move cursor backward, fixed-cadence batcher, two-pass finalize) — pure and tier-0 tested in `EarsCore`.
- Live segments to stdout, live file append, and `segment` events on the socket feed (notification only; disk is durable).
- Socket audio ingestion for `browser:<label>` sources with bounded backpressure; the browser plugin (separate deliverable) pushes tab audio in.
- **Delivers UC-3 and UC-4.**
- **Exit:** a live transcript is visible during a session with no garbled tail on the no-backspace sink; browser-routed audio behaves as a first-class source.

## Later / candidate

- Native Anthropic-SDK LLM backend (streaming, caching) behind the existing interface.
- Additional ASR backends via the subprocess adapter (whisper.cpp, NeMo) for coverage/comparison.
- Search/index tool over transcripts (the JSONL/frontmatter formats already support this).
- Front-ends (menu-bar app, browser-plugin UI) consuming the socket feed and file outputs — out of scope for the core suite but enabled by its interfaces.

## Cross-cutting, every phase

- **Test-driven development and small, incremental commits** per [engineering practices](./engineering-practices.md); CI runs the suite from commit one, with model-accuracy benchmarks gated for the ASR/diarization path. Each phase's exit criteria are expressed as green tests at the appropriate tier.
- **Developer ID signing + notarization from day one** per [distribution](./distribution.md); every distributed build is signed, notarized, and stapled in CI — never ad-hoc signed with Gatekeeper workarounds. `earsd` registers via `SMAppService` with status reconciled against reality.
- Structured logging sufficient to reconstruct each run; performance signposts on expensive stages.
- Concise `--help` on every command and subcommand.
- Atomic writes everywhere; loud, non-zero failures; no silent degradation.
- Schema-versioned on-disk formats; unknown schema rejected with a clear message.

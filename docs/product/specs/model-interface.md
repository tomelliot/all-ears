# Spec: Model interface (ASR & diarization)

The transcription model is composable. `transcribe` depends on an interface, not on any specific model. Parakeet is the first backend.

## ASR backend protocol

Capability-by-protocol, **not** a god-object `switch` on engine type. This is the single most important design decision here and the corpus is unanimous: the maintainable shape is a **small base protocol plus optional capability protocols** layered on top; the anti-pattern is an engine-discriminating dispatch that grows into a god-object (macparakeet's `STTRuntime` switch, self-flagged by its authors for exactly this). Two implementations ship: a native one and a subprocess adapter.

```swift
// Base: every backend does this much.
protocol Transcriber {
    var info: ModelInfo { get }              // name, version, languages, capability flags
    func load(_ options: LoadOptions) throws // load weights, pick ANE/GPU/CPU

    // Batch decode a mono PCM buffer into timed segments.
    func transcribe(_ audio: AudioBuffer, context: TranscribeContext) throws -> [Segment]
}

// Optional capabilities — a backend opts in by conforming; stubs simply don't.
protocol StreamingTranscriber: Transcriber {          // info.supportsStreaming
    // Caller owns continuity: decoder state is explicit and passed inout,
    // so the manager itself stays stateless across sources.
    func step(_ frames: AudioBuffer, state: inout DecoderState) throws -> [Segment]
}
protocol BiasingTranscriber: Transcriber {            // info.supportsBiasing
    func setBias(_ terms: [String]) throws            // decoder/CTC-level keyword boosting
}
protocol WordTimingTranscriber: Transcriber {}        // info.wordTimings  -> Segment.words[]
```

- `TranscribeContext` carries the **vocabulary/biasing terms**, language hint, and prior text for continuity.
- `Segment` carries `start`, `end`, `text`, optional `words[]` (with per-word timing/confidence), and `confidence`.
- **Capability flags on `ModelInfo`** (`supportsStreaming`, `supportsBiasing`, `wordTimings`) tell the pipeline what a backend can do; the pipeline checks the flag / `as?`-casts to the capability protocol rather than switching on model name. `supportsBiasing` in particular decides whether the known-word list is injected here or left entirely to `cleanup`.
- **Stateless manager, caller owns continuity.** Decoder state is passed **`inout`** (FluidAudio's pattern) so one manager serves many sources without holding per-source state, and so a light streaming manager and a vocab-boosted final manager can **share one `MLModel`** — the second instance then costs only decoder state, not a second model load.

### Backend 1 — native (default): Parakeet via FluidAudio

Runs NVIDIA Parakeet through **FluidAudio** on the **Apple Neural Engine / Metal** via Core ML — the low-latency, low-footprint default and the reason Swift is the suite's language. Provides word timings and streaming for `--follow`. The following integration specifics are load-bearing (each maps to a real crash or quality bug in the survey) and must be implemented, not discovered later:

- **Serialize ANE inference on macOS 14** (an `ANEInferenceGate`-style single-flight): concurrent Core ML inference on the ANE hits a **SIGBUS**. This is a hard crash we would otherwise ship.
- **Reconstruct word timings** from FluidAudio `TokenTiming` by merging `▁`-prefixed SentencePiece tokens into words — `Segment.words[]` depends on this.
- **Trailing-silence-pad short clips** before TDT decode, or the decoder drops the final word (FluidAudio issue #562).
- **Run the VAD on `.cpuOnly`** to avoid ANE contention with the ASR model during live work.
- **Pool/pre-warm ANE-aligned `MLMultiArray`** buffers to avoid per-inference allocation.
- **Auto-recover** a corrupt compiled Core ML model by re-downloading, and resume interrupted downloads.
- **Set `XDG_CACHE_HOME`** into the app container so FluidAudio caches inside the sandbox (documented Hex pitfall).
- Known-word biasing applied via `BiasingTranscriber` where the FluidAudio path supports decoder/CTC keyword boosting; otherwise deferred to `cleanup`.

### Backend 2 — subprocess adapter

Wraps any external model that speaks a defined **audio-in / JSON-out** contract (Python NeMo, `whisper.cpp`, etc.). Higher per-invocation overhead, maximum reach; lets a new model be trialled without touching Swift. The corpus converges on a specific, deadlock-free discipline:

- **`stdout` = JSON results, `stderr` = logs, strictly separated.** The tool passes a mono PCM/WAV stream (stdin or temp file) plus a JSON context (vocabulary, language); the process returns segments in the [sidecar JSON schema](../data-formats.md#canonical-json-sidecar-optional).
- **Drain both pipes with a detached task *before* `waitUntilExit()`** — otherwise a child that fills the 64 KB pipe buffer deadlocks against a parent blocked on exit.
- **Supervise long-lived backends** (localvoxtral's `BackendProcessSupervisor` is the template): `/health`-poll readiness, `AsyncStream` state mirroring, exponential-backoff restart, graceful-then-`SIGKILL`, and a **parent-PID watchdog on the child** so it dies if `earsd`/`transcribe` does.
- **Pin model weights to exact Hugging Face commits** with include-pattern lists kept in sync with the loader.

Reserve this supervision complexity for the subprocess adapter only — in-process FluidAudio avoids all of it.

Selection: `[transcribe].backend = "fluidaudio" | "subprocess"` (+ `model`, `compute`). Adding a backend means conforming to the base protocol plus whatever capability protocols it supports, or matching the subprocess contract — no changes to `transcribe` itself.

**Anti-pattern:** runtime `dlopen`/`dlsym` with cwd/env/bundle-path probing is fragile and sandbox-hostile — prefer linked frameworks or XPC.

## Diarization backend protocol

Diarization is a separate, optional stage with its own interface, so it can be enabled per run and swapped independently.

```swift
protocol Diarizer {
    var info: DiarizerInfo { get }
    // Assign stable speaker labels to a stream's audio over a time range.
    func diarize(_ audio: AudioBuffer) throws -> [SpeakerSpan]   // {start, end, speaker}
}
```

- **Channel-of-origin is the *primary* label; the diarizer only *refines*.** Source (mic vs `app:*`/`system`) already gives you-vs-them for free; the diarizer runs on a multi-speaker source (typically the far-end system/app channel) to split it into `Speaker N`. It never overrides source attribution.
- **Two-pass:** a fast streaming pass attributes speakers live during `--follow`; an offline batch pass over the saved samples afterward stabilises the speaker IDs (Detto's pattern). The durable transcript reflects the stabilised pass.
- **Dominant-speaker filtering for the mic:** optionally run diarization even on the single-speaker `mic` source and keep only the dominant speaker's spans, to reject background/overheard voices. Off by default (`mic` = `You`).
- Default backend: a pyannote/sherpa-class model, via the subprocess path where needed. Labels are stable within a transcript and can be remapped to names (see [speaker attribution](../data-formats.md#speaker-attribution)).
- **Anti-pattern:** faking diarization by concatenating mic + system transcripts and asking an LLM to guess speakers — that is not attribution.

## Known-word biasing summary

Applied in **both** stages by design:

1. **At transcription** — passed via `TranscribeContext` to backends where `supportsBiasing`, improving recognition of names/jargon directly.
2. **At cleanup** — the same list is a correction backstop in the LLM prompt, catching homophones any model missed.

The vocabulary is the merge of the global list and any per-session list; source and merge rules are in [data formats](../data-formats.md#vocabulary--known-word-lists).

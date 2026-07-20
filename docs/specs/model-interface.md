# Spec: model interface (ASR & diarization)

`transcribe` depends on interfaces, not on any specific model. Parakeet via FluidAudio is the shipping ASR backend.

## ASR backend protocols

Capability-by-protocol, not a god-object `switch` on engine type: a small base protocol plus optional capability protocols a backend opts into. The pipeline checks capability flags / casts to the capability protocol — it never switches on a model name.

```swift
// Base: every backend does this much.
protocol Transcriber {
    var info: ModelInfo { get }              // name, version, capability flags
    func load(_ options: LoadOptions) throws // load weights, pick ANE/GPU/CPU

    // Batch decode a mono PCM buffer into timed segments.
    func transcribe(_ audio: AudioBuffer, context: TranscribeContext) throws -> [Segment]
}

// Optional capabilities — a backend opts in by conforming.
protocol StreamingTranscriber: Transcriber {          // info.supportsStreaming
    // Caller owns continuity: decoder state is explicit and passed inout,
    // so the manager itself stays stateless across sources.
    func step(_ frames: AudioBuffer, state: inout DecoderState) throws -> [Segment]
}
protocol BiasingTranscriber: Transcriber {            // info.supportsBiasing
    func setBias(_ terms: [String]) throws            // decoder-level keyword boosting
}
```

- `TranscribeContext` carries vocabulary/biasing terms, language hint, and prior text for continuity. `Segment` carries `start`, `end`, `text`, optional `words[]` with per-word timing/confidence.
- **Stateless manager, caller owns continuity:** decoder state is passed `inout`, so one manager serves many sources without holding per-source state, and streaming + batch use can share one loaded model.
- `supportsBiasing` decides whether the known-word list is injected at decode or left entirely to `cleanup`.

### The Parakeet/FluidAudio backend

Runs NVIDIA Parakeet through FluidAudio on the Apple Neural Engine via Core ML. Conforms to `Transcriber` and `StreamingTranscriber` (TDT decoder state threaded per step); it does **not** yet conform to `BiasingTranscriber`, so vocabulary currently applies only at `cleanup`.

Integration specifics that are load-bearing (each maps to a real crash or quality bug):

- **Serialize ANE inference** (single-flight gate): concurrent Core ML inference on the ANE can SIGBUS on macOS 14.
- **Reconstruct word timings** by merging `▁`-prefixed SentencePiece tokens into words.
- **Pad trailing silence on short clips** before batch TDT decode, or the decoder drops the final word.
- **Run the VAD on CPU** to avoid ANE contention with the ASR model during live work.
- **Auto-recover** a corrupt compiled Core ML model by re-downloading; resume interrupted downloads; keep the model cache inside the sandbox (`XDG_CACHE_HOME`).

### Subprocess adapter (not yet implemented)

A planned second backend wraps any external model speaking an audio-in / JSON-out contract (Python NeMo, `whisper.cpp`), so new models can be trialled without touching Swift. The known discipline for it, when built: stdout = JSON results and stderr = logs, strictly separated; drain both pipes before waiting on exit (64 KB pipe-buffer deadlock); supervise long-lived children with health checks, backoff restart, and a parent-PID watchdog; pin weights to exact upstream commits.

## Diarization protocol (no shipping backend yet)

Diarization is a separate, optional stage with its own interface:

```swift
protocol Diarizer {
    var info: DiarizerInfo { get }
    func diarize(_ audio: AudioBuffer) throws -> [SpeakerSpan]   // {start, end, speaker}
}
```

The protocol exists with a test-support null conformer only; no real backend ships, and `transcribe` currently labels segments by source alone. Design constraints for the eventual implementation:

- **Channel-of-origin is the primary label; the diarizer only refines.** Source separation already gives you-vs-them; the diarizer splits a multi-speaker source (typically the far end) into `Speaker N`. It never overrides source attribution.
- **Two-pass:** a fast streaming pass for live attribution, an offline batch pass to stabilise speaker IDs; the durable transcript reflects the stabilised pass.
- Labels are stable within a transcript and remappable to names (see [speaker attribution](../data-formats.md#speaker-attribution)).
- **Anti-pattern:** faking diarization by concatenating per-source transcripts and asking an LLM to guess speakers — that is not attribution.

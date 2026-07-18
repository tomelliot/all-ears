/// The voice-activity-detection seam: classify a source's audio into coarse
/// speech/silence spans that index the ring buffer for silence-skipping.
///
/// - Design rationale (no Swift signature exists in the docs; shaped from
///   `docs/specs/capture-daemon.md`): the VAD is a pluggable backend (default
///   Silero-class) that runs per source and emits `vad` spans with padding /
///   min-silence applied. It is an *index*, not a recording gate — all audio is
///   written regardless. Modelled as a single batch call mapping a buffer to
///   ``VADSpan``s (offsets relative to the buffer), mirroring the compute-bound,
///   synchronous `throws` shape of ``Transcriber`` so the daemon can run it on a
///   worker (deliberately `.cpu` to avoid ANE contention with the ASR model).
///
/// - Phase 1 (`EnergyVAD`, run by `CaptureActor` against real
///   `MicCaptureBackend` audio in a live `earsd`) proved this shape
///   unchanged: ``detect(in:)`` is still a single stateless batch call, no
///   `inout` state parameter was added. Padding/min-silence parameters did
///   arrive via config as expected (`[earsd.vad].speech_pad_ms`/
///   `min_silence_ms`, read into `EnergyVAD`'s own properties). The
///   cross-buffer-continuity question this doc comment originally raised is
///   still open, not resolved: `CaptureActor` calls `detect(in:)` once per
///   incoming buffer and merges min-silence/padding only *within* that
///   buffer, so a speech run split across a buffer boundary is not merged
///   across the call. Whether real buffer sizes (`MicCaptureBackend` batches
///   variable-sized reads off its ring, not fixed to `min_silence_ms`) make
///   this matter in practice hasn't been revisited under live capture. If it
///   does, this remains the natural place to add an `inout` state parameter
///   like ``StreamingTranscriber/step(_:state:)``, exactly as originally
///   anticipated here.
public protocol VAD: Sendable {
  /// Classify a mono PCM buffer into consecutive speech/silence spans, with
  /// offsets relative to the start of `audio`.
  func detect(in audio: AudioBuffer) throws -> [VADSpan]
}

/// Optional capability marker: the backend populates `Segment.words` with
/// per-word timing and confidence, gated by `ModelInfo.wordTimings`.
///
/// A pure marker protocol — conformance (or an `as?` cast succeeding) is the
/// signal; the word timings themselves arrive on the ``Segment`` returned by the
/// base `transcribe`/`step`. Transcribed from `docs/specs/model-interface.md`.
public protocol WordTimingTranscriber: Transcriber {}

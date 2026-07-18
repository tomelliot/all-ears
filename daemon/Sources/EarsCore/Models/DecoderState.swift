/// Explicit, caller-owned continuity state for streaming decoding.
///
/// Passed `inout` to ``StreamingTranscriber/step(_:state:)`` so the transcription
/// manager itself stays stateless across sources (FluidAudio's pattern): one
/// manager serves many sources, and a light streaming instance and a
/// vocab-boosted final instance can share one underlying model, the second
/// costing only decoder state rather than a second model load.
///
/// - Note: Provisional. The fields here are the minimum a streaming caller needs
///   to seed and thread continuity; the real token/hidden-decoder state is added
///   by the FluidAudio shim in a later phase, which owns the actual TDT/CTC
///   representation. Start a fresh stream with `DecoderState()`.
public struct DecoderState: Sendable, Hashable {
  /// Text decoded so far in this stream, for continuity across `step` calls.
  public var priorText: String
  /// Number of audio frames consumed so far in this stream.
  public var framesConsumed: Int

  public init(priorText: String = "", framesConsumed: Int = 0) {
    self.priorText = priorText
    self.framesConsumed = framesConsumed
  }
}

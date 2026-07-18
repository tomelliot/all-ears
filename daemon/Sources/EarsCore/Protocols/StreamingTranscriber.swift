/// Optional capability: incremental (streaming) decoding, gated by
/// `ModelInfo.supportsStreaming`.
///
/// The caller owns continuity — decoder state is explicit and passed `inout` — so
/// the transcription manager itself stays stateless across sources. Transcribed
/// from `docs/specs/model-interface.md`.
public protocol StreamingTranscriber: Transcriber {
  /// Decode the next block of frames, threading continuity through `state`.
  func step(_ frames: AudioBuffer, state: inout DecoderState) throws -> [Segment]
}

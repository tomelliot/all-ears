/// Optional capability: decoder/CTC-level keyword boosting from a known-word
/// list, gated by `ModelInfo.supportsBiasing`.
///
/// When a backend supports biasing, the merged vocabulary is injected here at
/// transcription; otherwise correction is deferred entirely to `cleanup`.
/// Transcribed from `docs/specs/model-interface.md`.
public protocol BiasingTranscriber: Transcriber {
  /// Set the biasing terms applied to subsequent decodes.
  func setBias(_ terms: [String]) throws
}

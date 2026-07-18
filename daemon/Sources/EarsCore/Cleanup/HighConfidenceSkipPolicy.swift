/// The skip-high-confidence-utterances guardrail from `docs/product/specs/
/// llm-stages.md`: "don't send already-clean, high-ASR-confidence text to
/// the LLM at all -- saves cost and avoids needless drift."
///
/// A pure decision over ``Segment/confidence``: a segment the ASR backend
/// itself is already confident about is left untouched by `cleanup` rather
/// than risking the accept/fallback guardrail (``CleanupValidator``) ever
/// needing to run at all. A segment with no reported confidence (a backend
/// that doesn't report one) is never skipped -- "high confidence" cannot be
/// established, so it goes through cleanup like any other segment.
public struct HighConfidenceSkipPolicy: Sendable {
  /// The inclusive confidence threshold at or above which a segment is
  /// skipped. No exact value is prescribed in the spec; `0.95` is a
  /// conservative default, configurable per `[cleanup]` settings later.
  public var minConfidence: Double

  public init(minConfidence: Double = 0.95) {
    self.minConfidence = minConfidence
  }

  /// Whether `segment` is confident enough to skip sending through cleanup.
  public func shouldSkip(_ segment: Segment) -> Bool {
    guard let confidence = segment.confidence else { return false }
    return confidence >= minConfidence
  }
}

/// Per-word timing and confidence within a ``Segment``.
///
/// Populated by a ``WordTimingTranscriber`` (for the native Parakeet backend,
/// reconstructed by merging `▁`-prefixed SentencePiece tokens into words). Times
/// are seconds relative to the start of the decoded range, matching the canonical
/// JSON sidecar's `words[]` shape in `docs/data-formats.md`.
public struct WordTiming: Sendable, Hashable, Codable {
  public var text: String
  /// Start offset in seconds from the range start.
  public var start: Double
  /// End offset in seconds from the range start.
  public var end: Double
  /// Model confidence in `[0, 1]`, when the backend reports it.
  public var confidence: Double?

  public init(text: String, start: Double, end: Double, confidence: Double? = nil) {
    self.text = text
    self.start = start
    self.end = end
    self.confidence = confidence
  }
}

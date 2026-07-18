/// A timed unit of transcribed text produced by a ``Transcriber``.
///
/// Times are seconds relative to the start of the decoded range (not wall-clock
/// instants), matching the canonical JSON sidecar in `docs/data-formats.md`; the
/// renderer combines these with a session's range start to place segments on the
/// wall clock. ``words`` is empty unless the backend is a ``WordTimingTranscriber``.
public struct Segment: Sendable, Hashable, Codable {
  /// Start offset in seconds from the range start.
  public var start: Double
  /// End offset in seconds from the range start.
  public var end: Double
  public var text: String
  /// Per-word timings; empty when the backend does not provide word timings.
  public var words: [WordTiming]
  /// Segment-level confidence in `[0, 1]`, when the backend reports it.
  public var confidence: Double?

  public init(
    start: Double,
    end: Double,
    text: String,
    words: [WordTiming] = [],
    confidence: Double? = nil
  ) {
    self.start = start
    self.end = end
    self.text = text
    self.words = words
    self.confidence = confidence
  }
}

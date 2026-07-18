/// A stretch of audio attributed to one speaker by a ``Diarizer``.
///
/// Times are seconds relative to the start of the diarized range. `speaker` is a
/// label stable within a transcript (e.g. `Speaker 2`); channel-of-origin (the
/// source) remains the primary attribution and the diarizer only refines within a
/// multi-speaker source — it never overrides source attribution.
public struct SpeakerSpan: Sendable, Hashable, Codable {
  /// Start offset in seconds from the range start.
  public var start: Double
  /// End offset in seconds from the range start.
  public var end: Double
  /// Stable speaker label within the transcript (e.g. `Speaker 2`).
  public var speaker: String

  public init(start: Double, end: Double, speaker: String) {
    self.start = start
    self.end = end
    self.speaker = speaker
  }
}

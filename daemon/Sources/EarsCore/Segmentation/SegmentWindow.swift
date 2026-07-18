/// One contiguous, speech-bearing window ``NaturalPauseSegmenter`` produces:
/// a model-input-worthy slice of a requested range, pre-roll already
/// applied.
///
/// Offsets are seconds relative to the analysed range's start, matching the
/// relative-offset convention ``VADSpan``/``Segment``/``WordTiming`` share
/// (see ``ReconstructedRange``'s doc comment) -- so a caller lines this up
/// with the same range's chunks/VAD spans without a second conversion.
public struct SegmentWindow: Sendable, Hashable {
  public var start: Double
  public var end: Double

  public init(start: Double, end: Double) {
    self.start = start
    self.end = end
  }
}

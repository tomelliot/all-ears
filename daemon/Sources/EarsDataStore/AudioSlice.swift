import EarsCore

/// One decoded, segment-worthy slice of audio ``SegmentedAudioReader``
/// produces: a ``NaturalPauseSegmenter`` window's audio, already read off
/// disk, paired with the wall-clock range it covers -- ready to hand to a
/// ``Transcriber``.
public struct AudioSlice: Sendable, Hashable {
  /// The slice's audio at the source's ASR sample rate.
  public var audio: AudioBuffer
  /// The wall-clock range this slice covers, so a caller can place the
  /// ``Transcriber``'s returned ``Segment`` offsets (relative to this
  /// slice) back onto the original requested range's timeline.
  public var range: TimeRange

  public init(audio: AudioBuffer, range: TimeRange) {
    self.audio = audio
    self.range = range
  }
}

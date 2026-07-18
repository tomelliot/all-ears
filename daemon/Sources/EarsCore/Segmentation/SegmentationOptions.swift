/// Tuning knobs for ``NaturalPauseSegmenter``.
///
/// Neither knob is (yet) exposed in `docs/configuration.md`'s `[transcribe]`
/// table, so these defaults are this component's own until a follow-up
/// wires CLI/config overrides through.
public struct SegmentationOptions: Sendable, Hashable {
  /// The minimum silence gap, in seconds, between two speech spans that
  /// causes them to become separate segment windows rather than being
  /// merged into one. Below this, per `docs/product/specs/transcribe.md`'s
  /// "segment at natural pauses, not fixed cuts", the pause is a mid-thought
  /// breath, not an utterance boundary.
  public var maxPauseSeconds: Double
  /// Seconds of audio to include before each window's speech onset, so "the
  /// first word isn't clipped" (`docs/product/specs/transcribe.md`).
  public var preRollSeconds: Double

  public init(maxPauseSeconds: Double = 1.5, preRollSeconds: Double = 0.3) {
    self.maxPauseSeconds = maxPauseSeconds
    self.preRollSeconds = preRollSeconds
  }
}

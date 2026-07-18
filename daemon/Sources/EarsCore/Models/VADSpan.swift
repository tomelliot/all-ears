/// A contiguous speech-or-silence span produced by a ``VAD``.
///
/// Times are seconds relative to the start of the analysed buffer; the daemon
/// translates them to wall-clock instants when it appends `vad` events to
/// `index.jsonl`. The index is a map for skipping silence, not a recording gate —
/// all audio is written regardless of VAD state.
public struct VADSpan: Sendable, Hashable, Codable {
  public var state: VADState
  /// Start offset in seconds from the start of the analysed buffer.
  public var start: Double
  /// End offset in seconds from the start of the analysed buffer.
  public var end: Double

  public init(state: VADState, start: Double, end: Double) {
    self.state = state
    self.start = start
    self.end = end
  }
}

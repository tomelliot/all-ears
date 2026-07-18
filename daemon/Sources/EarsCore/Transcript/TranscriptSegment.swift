/// A ``Segment`` attributed to a source and speaker turn, ready for transcript
/// rendering — the unit the Markdown body and JSON sidecar are both rendered
/// from (see `docs/data-formats.md`, which guarantees the two never disagree
/// for a given run because they render from the same data).
///
/// ``Segment`` itself carries no source/speaker (see its doc comment); that
/// attribution is a pipeline concern (source mapping + diarization, per
/// `docs/data-formats.md`'s "Speaker attribution" section) applied upstream of
/// rendering. One `TranscriptSegment` renders as exactly one Markdown heading
/// block and exactly one JSON sidecar segment — turn-grouping (merging
/// consecutive same-speaker ASR segments into a turn) is the producer's job,
/// not the renderer's, since the renderer has no basis for choosing how to
/// merge word arrays or text across segments it wasn't told are one turn.
public struct TranscriptSegment: Sendable, Hashable {
  public var source: SourceID
  /// The speaker label to display, e.g. `You` or `Speaker 2`.
  public var speaker: String
  public var segment: Segment
  /// Whether to record source provenance on this turn's Markdown heading as
  /// `<!-- source: ... -->`. Per `docs/data-formats.md`, this documents where
  /// a diarized `Speaker N` label came from; set by the attribution stage
  /// (not inferred from the label text here) so that renaming a speaker
  /// label later doesn't change rendering behaviour.
  public var sourceProvenance: Bool

  public init(source: SourceID, speaker: String, segment: Segment, sourceProvenance: Bool = false) {
    self.source = source
    self.speaker = speaker
    self.segment = segment
    self.sourceProvenance = sourceProvenance
  }
}

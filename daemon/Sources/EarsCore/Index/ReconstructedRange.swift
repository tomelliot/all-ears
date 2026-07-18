/// The result of mapping a requested wall-clock ``TimeRange`` onto a source's
/// index events — the "map wall-clock time to audio" step `docs/data-formats.md`
/// describes for `index.jsonl`. A future `transcribe` implementation reads
/// audio via ``chunks``, skips silence via ``vadSpans``, and logs (without
/// failing) any ``gaps`` as known-missing coverage.
public struct ReconstructedRange: Sendable, Hashable {
  /// The wall-clock range that was requested.
  public var requested: TimeRange
  /// Chunks whose stored coverage overlaps ``requested``, ordered by start.
  /// A caller reads these files to obtain audio for the range.
  public var chunks: [IndexedChunk]
  /// VAD spans overlapping ``requested``, clipped to it, ordered by start.
  /// Offsets are seconds relative to `requested.start`, matching the
  /// relative-offset convention ``Segment``/``WordTiming`` use for a decoded
  /// range — so a caller can line up VAD spans with segments without a
  /// second wall-clock conversion.
  public var vadSpans: [VADSpan]
  /// Sub-ranges of ``requested`` known to be missing audio (from `gap`
  /// events), clipped to ``requested`` and ordered by start. Per
  /// `docs/data-formats.md`, gaps are known-missing — logged, not fatal.
  public var gaps: [TimeRange]

  public init(requested: TimeRange, chunks: [IndexedChunk], vadSpans: [VADSpan], gaps: [TimeRange])
  {
    self.requested = requested
    self.chunks = chunks
    self.vadSpans = vadSpans
    self.gaps = gaps
  }
}

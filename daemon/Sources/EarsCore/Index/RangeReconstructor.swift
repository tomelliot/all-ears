/// Reconstructs the audio, speech activity, and known gaps covering a
/// requested wall-clock range from a source's index events.
///
/// This is the core "map wall-clock time to audio" logic `docs/data-formats.md`
/// describes: given a ``TimeRange`` and the (already-parsed) events for a
/// source's `index.jsonl`, determine which `chunk` files to read, which `vad`
/// spans indicate speech within the range, and which sub-ranges are known to
/// be missing per `gap` events.
public enum RangeReconstructor {
  /// - Parameters:
  ///   - requested: The wall-clock range to reconstruct.
  ///   - events: A source's index events, in any order (does not need to be
  ///     pre-sorted; see ``IndexLog`` for the recommended way to obtain
  ///     these from raw `index.jsonl` contents).
  public static func reconstruct(_ requested: TimeRange, events: [IndexEvent]) -> ReconstructedRange
  {
    var chunks: [IndexedChunk] = []
    var vadSpans: [VADSpan] = []
    var gaps: [TimeRange] = []

    for event in events {
      switch event {
      case .chunk(let start, let end, let file, let frames):
        let chunkRange = TimeRange(start: start, end: end)
        guard chunkRange.overlaps(requested) else { continue }
        chunks.append(IndexedChunk(range: chunkRange, file: file, frames: frames))

      case .vad(let state, let start, let end):
        let vadRange = TimeRange(start: start, end: end)
        guard let clipped = clip(vadRange, to: requested) else { continue }
        vadSpans.append(
          VADSpan(
            state: state,
            start: clipped.start.interval(since: requested.start),
            end: clipped.end.interval(since: requested.start)
          ))

      case .gap(let start, let end, _):
        let gapRange = TimeRange(start: start, end: end)
        guard let clipped = clip(gapRange, to: requested) else { continue }
        gaps.append(clipped)

      case .evict:
        // Eviction is a record of past deletion, not part of a
        // range's audio, speech, or gap coverage.
        continue
      }
    }

    chunks.sort { $0.range.start < $1.range.start }
    vadSpans.sort { $0.start < $1.start }
    gaps.sort { $0.start < $1.start }

    return ReconstructedRange(requested: requested, chunks: chunks, vadSpans: vadSpans, gaps: gaps)
  }

  /// The overlap of `range` with `bounds`, or `nil` if they don't overlap
  /// under the half-open `[start, end)` convention ``TimeRange`` uses
  /// throughout the suite.
  private static func clip(_ range: TimeRange, to bounds: TimeRange) -> TimeRange? {
    let start = max(range.start, bounds.start)
    let end = min(range.end, bounds.end)
    guard start < end else { return nil }
    return TimeRange(start: start, end: end)
  }
}

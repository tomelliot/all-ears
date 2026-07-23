/// Turns a range's VAD spans (as reconstructed by ``RangeReconstructor``)
/// into the sequence of ``SegmentWindow``s a transcriber should be handed,
/// per `docs/specs/transcribe.md`'s behaviour #3: "Segment at
/// natural pauses, not fixed cuts... include a short pre-roll before each
/// utterance onset."
///
/// Pure function of the already-computed VAD spans and a duration -- no I/O,
/// no audio bytes -- so silence-skipping and natural-pause splitting are
/// both tier-0 testable without a fixture source directory.
public enum NaturalPauseSegmenter {
  /// - Parameters:
  ///   - vadSpans: A range's VAD spans, in any order (as
  ///     ``ReconstructedRange/vadSpans``, offsets relative to the range
  ///     start). Only ``VADState/speech`` spans produce windows; silence
  ///     spans are dropped, which is exactly the "no segment for a stretch
  ///     with no VAD-flagged speech" silence-skipping behaviour.
  ///   - rangeDuration: The analysed range's total duration in seconds;
  ///     window ends never exceed this.
  ///   - options: Pause-merge threshold and pre-roll length.
  public static func segments(
    vadSpans: [VADSpan],
    rangeDuration: Double,
    options: SegmentationOptions = SegmentationOptions()
  ) -> [SegmentWindow] {
    let speechSpans = vadSpans.filter { $0.state == .speech }.sorted { $0.start < $1.start }
    guard !speechSpans.isEmpty else { return [] }

    // Merge speech spans separated by a pause shorter than maxPauseSeconds:
    // a short breath doesn't split an utterance into two segments.
    var merged: [(start: Double, end: Double)] = [(speechSpans[0].start, speechSpans[0].end)]
    for span in speechSpans.dropFirst() {
      let last = merged[merged.count - 1]
      if span.start - last.end < options.maxPauseSeconds {
        merged[merged.count - 1].end = max(last.end, span.end)
      } else {
        merged.append((span.start, span.end))
      }
    }

    // Apply pre-roll per window, clamped so it never goes negative and
    // never eats back into the previous window's end (which would
    // duplicate audio across two overlapping windows).
    var windows: [SegmentWindow] = []
    var previousEnd = 0.0
    for span in merged {
      let start = max(previousEnd, span.start - options.preRollSeconds, 0)
      let end = min(rangeDuration, span.end)
      windows.append(SegmentWindow(start: start, end: end))
      previousEnd = end
    }
    return windows
  }
}

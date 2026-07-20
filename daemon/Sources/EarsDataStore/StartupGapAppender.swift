import EarsCore

/// Thin I/O composition of ``StartupGapDetector``'s pure decision with a
/// real `index.jsonl`: read the tail for the last known coverage end
/// (``IndexAppender/lastKnownEnd()``), decide whether a gap needs
/// recording, and append it if so.
public enum StartupGapAppender {
  /// - Returns: The `gap` event that was appended, or `nil` if none was
  ///   needed (see ``StartupGapDetector/gapEvent(afterLastKnownEnd:now:reason:)``).
  @discardableResult
  public static func detectAndAppend(
    now: Instant,
    reason: String = "daemon_restart",
    indexAppender: IndexAppender
  ) async throws -> IndexEvent? {
    // Read only the tail (``IndexAppender.lastKnownEnd()``) rather than
    // parsing the whole index: a multi-day source's `index.jsonl` can be
    // many megabytes, and `CaptureActor.start()` — which calls this on
    // every daemon restart — must not block for seconds on a single gap
    // decision. The append-only, time-ordered index guarantees the
    // maximum `end` lives at the tail.
    let lastKnownEnd = try await indexAppender.lastKnownEnd()
    guard
      let event = StartupGapDetector.gapEvent(
        afterLastKnownEnd: lastKnownEnd,
        now: now,
        reason: reason
      )
    else {
      return nil
    }
    try await indexAppender.append(event)
    return event
  }
}

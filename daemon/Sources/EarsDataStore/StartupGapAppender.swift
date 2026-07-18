import EarsCore

/// Thin I/O composition of ``StartupGapDetector``'s pure decision with a
/// real `index.jsonl`: read the file, parse it with ``IndexLog`` (already
/// built), decide whether a gap needs recording, and append it if so.
public enum StartupGapAppender {
  /// - Returns: The `gap` event that was appended, or `nil` if none was
  ///   needed (see ``StartupGapDetector/gapEvent(afterLastKnownEnd:now:reason:)``).
  @discardableResult
  public static func detectAndAppend(
    now: Instant,
    reason: String = "daemon_restart",
    indexAppender: IndexAppender
  ) async throws -> IndexEvent? {
    let contents = try await indexAppender.readContents()
    let parsed = IndexLog.parse(contents)
    guard
      let event = StartupGapDetector.gapEvent(
        afterLastKnownEnd: StartupGapDetector.lastKnownEnd(in: parsed.events),
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

import EarsCore

/// Pure decision logic for startup gap detection, per
/// `docs/specs/capture-daemon.md`'s "Ring buffer maintenance": "On startup
/// after downtime, emit a `gap` event covering the uncaptured interval."
///
/// Kept free of any I/O so it's unit-tested like any other `EarsCore`-style
/// pure function -- ``StartupGapAppender`` is the thin I/O wrapper that
/// reads a real `index.jsonl` and appends the result.
public enum StartupGapDetector {
  /// The latest instant a source's index already covers, across every
  /// event kind. `chunk`/`vad`/`gap` events all carry an `end` that extends
  /// coverage past their `start`; `evict` only records a past deletion and
  /// doesn't represent captured coverage, so it's excluded.
  ///
  /// - Returns: `nil` if `events` is empty (a brand-new source with no
  ///   coverage yet -- nothing to gap against on its first startup).
  public static func lastKnownEnd(in events: [IndexEvent]) -> Instant? {
    events.compactMap { event -> Instant? in
      switch event {
      case .chunk(_, let end, _, _): end
      case .vad(_, _, let end): end
      case .gap(_, let end, _): end
      case .evict: nil
      }
    }.max()
  }

  /// Decides whether a `gap` event should be recorded for the interval
  /// between a source's last known coverage and `now`.
  ///
  /// - Parameters:
  ///   - lastKnownEnd: The result of ``lastKnownEnd(in:)`` over the
  ///     source's existing index events, or `nil` for a source with no
  ///     prior coverage.
  ///   - now: The current instant, always injected.
  ///   - reason: The event's `reason` field; defaults to `"daemon_restart"`
  ///     per `docs/data-formats.md`'s `gap` event example.
  /// - Returns: `nil` when there's nothing to gap against (`lastKnownEnd`
  ///   is `nil`) or when no time has actually passed (`now <= lastKnownEnd`
  ///   -- a clean, instantaneous restart, or `now` not having advanced past
  ///   the last recorded coverage). Otherwise, the `gap` event covering
  ///   `[lastKnownEnd, now)`.
  public static func gapEvent(
    afterLastKnownEnd lastKnownEnd: Instant?,
    now: Instant,
    reason: String = "daemon_restart"
  ) -> IndexEvent? {
    guard let lastKnownEnd, lastKnownEnd < now else { return nil }
    return .gap(start: lastKnownEnd, end: now, reason: reason)
  }
}

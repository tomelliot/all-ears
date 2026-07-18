import Foundation

extension Instant {
  /// ISO-8601 UTC, millisecond precision, e.g. `2026-07-17T10:30:00.012Z` —
  /// the on-disk timestamp format `docs/logging.md` and `docs/data-formats.md`
  /// require. Shared by the JSON Lines encoder and the pretty renderer so the
  /// two never drift.
  ///
  /// A fresh `ISO8601DateFormatter` is built per call rather than
  /// shared/cached: simplest way to stay `Sendable`-clean across the
  /// concurrent test runner without a mutable shared instance, and formatter
  /// construction is not a hot path for log records.
  var iso8601Milliseconds: String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date(timeIntervalSince1970: secondsSinceEpoch))
  }
}

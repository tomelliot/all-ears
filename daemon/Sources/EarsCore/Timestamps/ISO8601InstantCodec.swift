import Foundation

/// Public ISO-8601 UTC string ↔ ``Instant`` conversion, for any caller (a CLI
/// flag, a parsed document field) that needs to round-trip the same
/// `2026-07-17T10:30:00Z`-shaped timestamp `docs/data-formats.md` uses
/// throughout. ``IndexTimestampCodec`` predates this type and is scoped
/// specifically to `index.jsonl` fields; it now delegates here rather than
/// duplicating the formatter logic.
///
/// A fresh `ISO8601DateFormatter` is created per call rather than cached in a
/// `static let`, for the same reason ``IndexTimestampCodec`` does: the
/// formatter is a mutable, non-`Sendable` class, and these calls are not a
/// hot path.
public enum ISO8601InstantCodec {
  /// Parses an ISO-8601 UTC timestamp, with or without fractional seconds.
  /// Returns `nil` if `string` is not a valid ISO-8601 UTC timestamp in either
  /// form.
  public static func parse(_ string: String) -> Instant? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: string) {
      return Instant(secondsSinceEpoch: date.timeIntervalSince1970)
    }

    let whole = ISO8601DateFormatter()
    whole.formatOptions = [.withInternetDateTime]
    if let date = whole.date(from: string) {
      return Instant(secondsSinceEpoch: date.timeIntervalSince1970)
    }

    return nil
  }

  /// Renders `instant` as an ISO-8601 UTC string with millisecond precision.
  public static func format(_ instant: Instant) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date(timeIntervalSince1970: instant.secondsSinceEpoch))
  }
}

import Foundation

/// ISO-8601 UTC string ↔ ``Instant`` conversion for `index.jsonl` fields.
///
/// `Instant`'s own `Codable` conformance is a plain `Double` (seconds since
/// epoch) by design — the string form is a renderer/parser concern owned by
/// the module that needs it (see `Instant`'s doc comment). `IndexEvent` needs
/// the on-disk ISO-8601 string form specified in `docs/data-formats.md`, so
/// that conversion lives here, scoped to the index event model.
///
/// A fresh `ISO8601DateFormatter` is created per call rather than cached in a
/// `static let`: the formatter is a mutable, non-`Sendable` class, and a
/// shared instance would either need `nonisolated(unsafe)` or reintroduce the
/// same shared-mutable-state problem `Instant` avoids by not touching the
/// clock. Index events are parsed at a low rate (line-by-line JSONL, not a
/// hot per-sample path), so the extra allocation is not a hot-path cost.
enum IndexTimestampCodec {
  /// Parses an ISO-8601 UTC timestamp, with or without fractional seconds
  /// (`docs/data-formats.md` uses millisecond fractions for `vad` events and
  /// whole seconds elsewhere). Returns `nil` if `string` is not a valid
  /// ISO-8601 UTC timestamp in either form.
  static func parse(_ string: String) -> Instant? {
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

  /// Renders `instant` as an ISO-8601 UTC string with millisecond precision,
  /// matching the `vad` event examples in `docs/data-formats.md`. Millisecond
  /// precision is used uniformly (rather than only when non-zero) so encoding
  /// is deterministic and independent of the value's magnitude.
  static func format(_ instant: Instant) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date(timeIntervalSince1970: instant.secondsSinceEpoch))
  }
}

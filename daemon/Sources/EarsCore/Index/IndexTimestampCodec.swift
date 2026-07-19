/// ISO-8601 UTC string ↔ ``Instant`` conversion for `index.jsonl` fields.
///
/// `Instant`'s own `Codable` conformance is a plain `Double` (seconds since
/// epoch) by design — the string form is a renderer/parser concern owned by
/// the module that needs it (see `Instant`'s doc comment). `IndexEvent` needs
/// the on-disk ISO-8601 string form specified in `docs/data-formats.md`, so
/// that conversion lives here, scoped to the index event model — delegating
/// to ``ISO8601InstantCodec`` (the public, general-purpose version of this
/// same conversion) rather than duplicating the formatter logic.
enum IndexTimestampCodec {
  /// Parses an ISO-8601 UTC timestamp, with or without fractional seconds
  /// (`docs/data-formats.md` uses millisecond fractions for `vad` events and
  /// whole seconds elsewhere). Returns `nil` if `string` is not a valid
  /// ISO-8601 UTC timestamp in either form.
  static func parse(_ string: String) -> Instant? {
    ISO8601InstantCodec.parse(string)
  }

  /// Renders `instant` as an ISO-8601 UTC string with millisecond precision,
  /// matching the `vad` event examples in `docs/data-formats.md`. Millisecond
  /// precision is used uniformly (rather than only when non-zero) so encoding
  /// is deterministic and independent of the value's magnitude.
  static func format(_ instant: Instant) -> String {
    ISO8601InstantCodec.format(instant)
  }
}

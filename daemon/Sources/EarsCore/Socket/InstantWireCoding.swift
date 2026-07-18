/// Generic ISO-8601 ⇄ ``Instant`` coding helpers for control-socket wire
/// types.
///
/// Several socket payloads (``SourceStatus``, ``EarsEvent/vad(source:state:t:)``,
/// ``SessionSummary``, the `mark`/`session.open` requests) each carry one or
/// more `Instant` fields that must render as ISO-8601 strings on the wire —
/// `Instant`'s own `Codable` is a plain-`Double` seconds-since-epoch form by
/// design (see that type's doc comment), so callers that need the string
/// form convert explicitly. ``IndexEvent`` has this same need for
/// `index.jsonl` and solves it with a pair of `fileprivate` helpers scoped
/// to its own `CodingKeys` type; this generalises that pattern across any
/// `CodingKey` type instead of copying it into every socket type below, and
/// reuses ``IndexTimestampCodec`` for the actual parse/format rather than
/// reimplementing ISO-8601 handling.
///
/// Named distinctly from `IndexEvent`'s `decodeInstant`/`encodeInstant` (not
/// an override or an ambiguity risk — that pair is `fileprivate` to
/// `IndexEvent.swift` and invisible here) purely so the two are never
/// confused when reading either file in isolation.
extension KeyedDecodingContainer {
  func decodeISO8601Instant(forKey key: Key) throws -> Instant {
    let raw = try decode(String.self, forKey: key)
    guard let instant = IndexTimestampCodec.parse(raw) else {
      throw DecodingError.dataCorruptedError(
        forKey: key,
        in: self,
        debugDescription: "Invalid ISO-8601 timestamp: \(raw)"
      )
    }
    return instant
  }

  func decodeISO8601InstantIfPresent(forKey key: Key) throws -> Instant? {
    guard let raw = try decodeIfPresent(String.self, forKey: key) else { return nil }
    guard let instant = IndexTimestampCodec.parse(raw) else {
      throw DecodingError.dataCorruptedError(
        forKey: key,
        in: self,
        debugDescription: "Invalid ISO-8601 timestamp: \(raw)"
      )
    }
    return instant
  }
}

extension KeyedEncodingContainer {
  mutating func encodeISO8601Instant(_ instant: Instant, forKey key: Key) throws {
    try encode(IndexTimestampCodec.format(instant), forKey: key)
  }

  mutating func encodeISO8601InstantIfPresent(_ instant: Instant?, forKey key: Key) throws {
    try encodeIfPresent(instant.map(IndexTimestampCodec.format), forKey: key)
  }
}

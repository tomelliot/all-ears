/// Translates ``TranscriptSegment``/``Segment``/``WordTiming`` into the
/// canonical `.transcript.json` sidecar schema from `docs/data-formats.md`.
///
/// `Segment`'s and `WordTiming`'s `Codable` conformances do **not** match the
/// wire format directly, so this is a deliberate translation layer rather
/// than a reuse of their `Encodable` output:
/// - `Segment` has no `source`/`speaker` — those live on ``TranscriptSegment``,
///   added by the attribution stage upstream of rendering.
/// - `Segment.confidence` has no place in the sidecar schema (only
///   `words[].conf` does); it is intentionally dropped here.
/// - `WordTiming.text`/`.confidence` are keyed `text`/`confidence` by
///   `Codable`, but the wire format uses the short keys `w`/`conf`.
enum SidecarJSONRenderer {
  static func render(_ segments: [TranscriptSegment]) -> String {
    let root = JSONValue.object([
      ("schema", .int(1)),
      ("segments", .array(segments.map(segmentValue))),
    ])
    return JSON.render(root) + "\n"
  }

  private static func segmentValue(_ turn: TranscriptSegment) -> JSONValue {
    .object([
      ("start", .number(turn.segment.start)),
      ("end", .number(turn.segment.end)),
      ("source", .string(turn.source.rawValue)),
      ("speaker", .string(turn.speaker)),
      ("text", .string(turn.segment.text)),
      ("words", .array(turn.segment.words.map(wordValue))),
    ])
  }

  private static func wordValue(_ word: WordTiming) -> JSONValue {
    var pairs: [(key: String, value: JSONValue)] = [
      ("w", .string(word.text)),
      ("start", .number(word.start)),
      ("end", .number(word.end)),
    ]
    if let confidence = word.confidence {
      pairs.append(("conf", .number(confidence)))
    }
    return .object(pairs)
  }
}

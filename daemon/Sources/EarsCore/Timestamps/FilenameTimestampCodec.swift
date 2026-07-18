import Foundation

/// ``Instant`` ↔ filename-safe ISO-8601 string conversion, shared by chunk
/// filenames (`docs/data-formats.md`'s `2026-07-17T10-30-00Z.m4a`) and
/// session directory names (`2026-07-17T10-30-00Z_standup`).
///
/// This is deliberately a sibling of ``IndexTimestampCodec``, not a reuse of
/// it, because the two serialise different literal formats for different
/// reasons:
///
/// - ``IndexTimestampCodec`` renders `index.jsonl` field values: colons
///   intact (it's inside a JSON string, not a path component) and always
///   with millisecond fractional precision, uniformly, per its own doc
///   comment.
/// - `FilenameTimestampCodec` renders path components: colons are replaced
///   with `-` (`:` is awkward/unsafe in filenames), and whole-second
///   precision only, matching every literal example in `docs/data-formats.md`
///   — chunks are fixed-duration (default 30s) so sub-second chunk/session
///   start times don't occur in practice, and encoding always truncates
///   rather than rounding, so the same instant a caller wrote a chunk file
///   with is the same string it looks that file up by.
///
/// Parsing does reuse ``IndexTimestampCodec/parse(_:)`` for the actual
/// ISO-8601 interpretation once colons are restored, rather than
/// reimplementing date parsing.
public enum FilenameTimestampCodec {
  /// Renders `instant` as `YYYY-MM-DDTHH-MM-SSZ`, truncating any fractional
  /// seconds.
  public static func string(for instant: Instant) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let iso = formatter.string(from: Date(timeIntervalSince1970: instant.secondsSinceEpoch))
    return filenameSafe(iso)
  }

  /// Parses a filename-safe timestamp of the exact form ``string(for:)``
  /// produces. Returns `nil` if `string` is not exactly that form — in
  /// particular, a session directory name's trailing `_<slug>` is not
  /// stripped here; callers that need the timestamp prefix of a longer
  /// string are expected to slice it out first.
  ///
  /// `ISO8601DateFormatter` parses a leading valid timestamp even with
  /// trailing garbage after it, so the shape (`YYYY-MM-DDTHH-MM-SSZ`) is
  /// checked explicitly with a local `Regex` rather than relying on the
  /// formatter to reject it. The `Regex` is built per call, not cached in a
  /// `static let`, because `Regex` is not `Sendable` — the same tradeoff
  /// ``IndexTimestampCodec`` makes for its formatter, and parsing here runs
  /// at the same low, non-hot-path rate.
  public static func parse(_ string: String) -> Instant? {
    guard let shape = try? Regex(#"\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}Z"#) else { return nil }
    guard string.wholeMatch(of: shape) != nil else { return nil }
    guard let tIndex = string.firstIndex(of: "T") else { return nil }
    let datePart = String(string[string.startIndex..<tIndex])
    let timePart = string[tIndex...].replacingOccurrences(of: "-", with: ":")
    return IndexTimestampCodec.parse(datePart + timePart)
  }

  private static func filenameSafe(_ iso8601: String) -> String {
    guard let tIndex = iso8601.firstIndex(of: "T") else { return iso8601 }
    let datePart = String(iso8601[iso8601.startIndex..<tIndex])
    let timePart = iso8601[tIndex...].replacingOccurrences(of: ":", with: "-")
    return datePart + timePart
  }
}

/// A wall-clock instant, stored as seconds since the Unix epoch (UTC).
///
/// `Instant` is the suite's canonical timestamp type. On disk these render as
/// ISO-8601 UTC strings with millisecond precision (`index.jsonl`, `meta.toml`,
/// `session.toml`, transcript frontmatter — see `docs/data-formats.md`); the
/// string ↔ `Instant` conversion is a renderer/parser concern owned by other
/// modules, so this type deliberately carries no formatting logic.
///
/// It wraps a plain `Double` rather than `Foundation.Date` so that it is
/// Foundation-free, trivially constructible in tests, and never reaches for the
/// real clock. Reading the current instant goes through ``NowProviding`` /
/// ``SystemClock`` instead, keeping pure logic deterministic and testable.
public struct Instant: Sendable, Hashable, Comparable, Codable {
  /// Seconds since 1970-01-01T00:00:00Z (UTC). A `Double` keeps well under a
  /// microsecond of resolution at present-day magnitudes, comfortably beyond
  /// the millisecond precision the on-disk formats require.
  public var secondsSinceEpoch: Double

  public init(secondsSinceEpoch: Double) {
    self.secondsSinceEpoch = secondsSinceEpoch
  }

  /// Seconds elapsed from `other` to `self`; negative when `self` precedes `other`.
  public func interval(since other: Instant) -> Double {
    secondsSinceEpoch - other.secondsSinceEpoch
  }

  /// The instant `seconds` later than this one (negative moves earlier).
  public func advanced(by seconds: Double) -> Instant {
    Instant(secondsSinceEpoch: secondsSinceEpoch + seconds)
  }

  public static func < (lhs: Instant, rhs: Instant) -> Bool {
    lhs.secondsSinceEpoch < rhs.secondsSinceEpoch
  }
}

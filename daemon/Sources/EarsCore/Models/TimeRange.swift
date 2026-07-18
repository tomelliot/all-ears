/// A half-open span of wall-clock time, `[start, end)`.
///
/// The half-open convention matters for reconstructing audio from the index:
/// contiguous VAD spans (silence ending exactly where speech begins) must not be
/// treated as overlapping, and a chunk's `end` is the next chunk's `start`.
/// `contains` and `overlaps` both follow `[start, end)` accordingly.
///
/// `start` is expected to be `<= end`; the type does not enforce this (a caller
/// building a range from raw index data validates upstream), and a zero-width
/// range (`start == end`) is legal and contains no instant.
public struct TimeRange: Sendable, Hashable, Codable {
  public var start: Instant
  public var end: Instant

  public init(start: Instant, end: Instant) {
    self.start = start
    self.end = end
  }

  /// Length of the range in seconds.
  public var duration: Double {
    end.interval(since: start)
  }

  /// Whether `instant` lies in `[start, end)`.
  public func contains(_ instant: Instant) -> Bool {
    instant >= start && instant < end
  }

  /// Whether the two ranges share any interior instant. Touching ranges
  /// (`a.end == b.start`) do not overlap under the half-open convention.
  public func overlaps(_ other: TimeRange) -> Bool {
    start < other.end && other.start < end
  }
}

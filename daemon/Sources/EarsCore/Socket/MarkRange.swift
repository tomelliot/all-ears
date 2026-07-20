/// The time range a `mark` request retroactively turns into a session.
///
/// **Wire-shape decision:** `docs/specs/capture-daemon.md` describes `mark`
/// as "retroactively define a range (e.g. 'last 30m') as a session", which
/// matches the CLI's `ears mark --last 30m` exactly — so the primary wire
/// field is a relative ``lastSeconds`` (seconds, matching `--last`'s
/// duration). An alternative absolute ``absolute(start:end:)`` timestamp
/// pair is also accepted, for callers that already know the wall-clock
/// range rather than "how long ago" (e.g. a future non-CLI trigger).
///
/// Exactly one form is valid on the wire: `last_seconds`, or both `start`
/// and `end` — never both, never neither. ``ControlRequestFrame``'s decoder
/// (which owns the actual `Codable` logic, since these fields sit flat
/// alongside `mark`'s `sources`/`slug` inside the params object rather than
/// nested under a `range` key) enforces this and throws a `DecodingError`
/// otherwise, rather than silently preferring one form.
public enum MarkRange: Sendable, Hashable {
  /// The last `seconds` up to now (`ears mark --last 30m` → `1800`).
  case lastSeconds(Double)
  /// An explicit absolute wall-clock range.
  case absolute(start: Instant, end: Instant)
}

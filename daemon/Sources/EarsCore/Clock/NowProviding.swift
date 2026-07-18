/// The wall-clock seam: the single source of "what time is it now" for the suite.
///
/// Pure logic never calls the real clock directly; it takes a `NowProviding` and
/// asks for ``now()``. Production code injects ``SystemClock``; tests inject a
/// controllable fake (`ManualClock`, in `EarsCoreTestSupport`) so no test path
/// ever touches wall-clock time — a hard rule from `docs/engineering-practices.md`.
///
/// Named `NowProviding` rather than `Clock` to avoid colliding with the standard
/// library's `Clock` protocol (which is about durations and scheduling, not
/// wall-clock instants). The single `now()` requirement is intentionally the
/// minimum a timestamping daemon needs.
public protocol NowProviding: Sendable {
  /// The current wall-clock instant.
  func now() -> Instant
}

/// Pure exponential-backoff schedule for engine-rebuild retries.
///
/// `docs/specs/capture-daemon.md`'s device-route-resilience decision treats route
/// flaps as *transient* (distinct from permission denial): a rebuild that fails is
/// retried indefinitely, with the delay doubling from ``base`` up to a ``cap`` so
/// a persistently-wedged device is retried at most once per `cap` rather than
/// hot-spinning. The retry loop that consumes this lives in the backend; the delay
/// math is factored out here so it is deterministic and unit-tested.
public struct ExponentialBackoff: Sendable, Hashable {
  /// Delay for the first retry (attempt 0). Default 100 ms.
  public var base: Duration
  /// Ceiling the delay never exceeds. Default ~5 s.
  public var cap: Duration
  /// Per-attempt growth factor. Default 2 (doubling).
  public var multiplier: Int

  public init(
    base: Duration = .milliseconds(100),
    cap: Duration = .seconds(5),
    multiplier: Int = 2
  ) {
    self.base = base
    self.cap = cap
    self.multiplier = multiplier
  }

  /// The delay before retry `attempt` (0-based): `base * multiplier^attempt`,
  /// clamped to `cap`. Attempt 0 is `base`.
  public func delay(forAttempt attempt: Int) -> Duration {
    guard attempt > 0 else { return Swift.min(base, cap) }
    var delay = base
    for _ in 0..<attempt {
      delay = delay * multiplier
      if delay >= cap { return cap }
    }
    return Swift.min(delay, cap)
  }
}

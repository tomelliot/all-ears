import EarsCore
import Synchronization

/// A controllable ``NowProviding`` for tests: time only moves when the test moves
/// it, so no test path ever touches the real wall clock (the hard rule from
/// `docs/engineering-practices.md`).
///
/// Backed by a `Mutex` rather than an `actor` so `now()` stays synchronous and
/// matches the ``NowProviding`` requirement; the lock guards the single stored
/// instant, which lets the type be genuinely `Sendable` without `@unchecked`.
public final class ManualClock: NowProviding {
  private let current: Mutex<Instant>

  public init(_ start: Instant = Instant(secondsSinceEpoch: 0)) {
    current = Mutex(start)
  }

  public func now() -> Instant {
    current.withLock { $0 }
  }

  /// Move the clock to an exact instant.
  public func set(_ instant: Instant) {
    current.withLock { $0 = instant }
  }

  /// Advance the clock by `seconds` (negative moves it back).
  public func advance(by seconds: Double) {
    current.withLock { $0 = $0.advanced(by: seconds) }
  }
}

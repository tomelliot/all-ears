import Synchronization

/// A monotonically-increasing generation counter that makes engine teardown safe
/// against in-flight realtime callbacks.
///
/// This is `docs/architecture.md`'s "generation counters guard every teardown"
/// pattern — the most load-bearing correctness property in the capture path.
/// The flow: when a tap is installed, the backend captures the gate's current
/// ``generation``; every callback re-checks it with ``isCurrent(_:)`` before
/// publishing samples. Teardown (stop, or a route-change rebuild) calls
/// ``invalidate()`` *first*, so any callback still draining from the old engine
/// instance sees a stale generation and drops its data rather than corrupting a
/// freshly-started session after a device hot-swap.
///
/// Backed by a lock-free ``Atomic`` so the check on the realtime audio thread is
/// wait-free. Genuinely `Sendable` — no `@unchecked` needed.
public final class GenerationGate: Sendable {
  private let current = Atomic<UInt64>(0)

  public init() {}

  /// The live generation. A callback captures this at tap-install time.
  public var generation: UInt64 {
    current.load(ordering: .acquiring)
  }

  /// `true` if `generation` is still the live one — i.e. the caller's engine
  /// instance has not been torn down.
  public func isCurrent(_ generation: UInt64) -> Bool {
    current.load(ordering: .acquiring) == generation
  }

  /// Invalidate the current generation, returning the new live value. Callers
  /// must invoke this *before* stopping/removing the tap so late callbacks are
  /// recognised as stale.
  @discardableResult
  public func invalidate() -> UInt64 {
    current.wrappingAdd(1, ordering: .acquiringAndReleasing).newValue
  }
}

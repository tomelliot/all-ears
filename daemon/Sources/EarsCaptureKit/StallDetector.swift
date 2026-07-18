import EarsCore

/// Pure stall-detection decision for the capture stall watchdog.
///
/// The spec (`docs/specs/capture-daemon.md` §"Isolation option for the riskiest
/// syscalls") requires a stall watchdog *unconditionally* for an in-process
/// capture backend: a wedged engine yields no error and no EOF, so nothing else
/// signals the failure. Rather than port the spec's Unix `select()` framing
/// literally — which suits the external-binary tap option, not in-process
/// Swift/Core Audio — the watchdog is a periodic heartbeat check: the tap
/// callback stamps a "last activity" instant, and if too long passes with no
/// callback while capture is expected to be active, the engine is presumed
/// wedged and recovery (the same rebuild path as a route change) is triggered.
///
/// This type is the pure decision; the periodic loop and the clock live in the
/// backend so the decision stays deterministic and unit-tested.
public struct StallDetector: Sendable, Hashable {
  /// Maximum silence, in seconds, tolerated between tap callbacks before the
  /// engine is judged stalled while capture is active.
  public var threshold: Double

  public init(threshold: Double) {
    self.threshold = threshold
  }

  /// Whether the engine looks stalled at `now`.
  ///
  /// - Parameters:
  ///   - lastActivity: instant of the most recent tap callback, or `nil` if no
  ///     callback has fired since capture (re)started.
  ///   - startedAt: instant capture was expected to begin producing. A `nil`
  ///     `lastActivity` is judged against this so a never-firing engine is
  ///     caught, while giving the engine one full threshold window to warm up.
  ///   - now: the current instant.
  public func isStalled(lastActivity: Instant?, startedAt: Instant, now: Instant) -> Bool {
    let reference = lastActivity ?? startedAt
    return now.interval(since: reference) >= threshold
  }
}

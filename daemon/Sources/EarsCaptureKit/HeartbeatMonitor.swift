import EarsCore
import Synchronization

/// Records the instant of the most recent tap callback so the stall watchdog can
/// tell a live engine from a wedged one.
///
/// The realtime tap stamps ``beat(_:)`` each callback; the watchdog reads
/// ``last`` off the audio thread. A single `Mutex` guards one optional `Instant`,
/// which keeps the type genuinely `Sendable` (no `@unchecked` — that exception is
/// reserved for the ring). ``reset()`` clears the stamp when capture (re)starts so
/// a fresh engine is judged from its start, not a stale previous beat.
public final class HeartbeatMonitor: Sendable {
  private let lastBeat = Mutex<Instant?>(nil)

  public init() {}

  /// The instant of the most recent beat, or `nil` since the last ``reset()``.
  public var last: Instant? {
    lastBeat.withLock { $0 }
  }

  /// Stamp a callback at `instant`. Called from the realtime tap thread.
  public func beat(_ instant: Instant) {
    lastBeat.withLock { $0 = instant }
  }

  /// Clear the stamp; call when capture (re)starts.
  public func reset() {
    lastBeat.withLock { $0 = nil }
  }
}

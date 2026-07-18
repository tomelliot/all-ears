/// Tracks the daemon's power/idle suspension state per
/// `docs/specs/capture-daemon.md`'s "Power/idle awareness" requirement:
/// system sleep, display sleep, and screen lock are **independent**
/// suspension sources. A caller waking from system sleep while the screen
/// is still locked must keep reporting suspended, since the lock flag holds
/// independently of the sleep flag that just cleared — hence ``isSuspended``
/// is `true` whenever *any* source is active, not a count or a single
/// merged flag.
///
/// Immutable-update value type: each `with...` method returns a new state
/// rather than mutating in place, so a caller holds it as a `var` and
/// reassigns on each transition (`state = state.withScreenLocked(true)`).
/// This keeps the type trivially `Sendable` and its history easy to reason
/// about — no aliasing surprises from a shared mutable reference.
public struct SuspensionState: Sendable, Hashable {
  /// Whether the system is asleep (the machine as a whole is suspended).
  public var isSystemAsleep: Bool
  /// Whether the display is asleep (the machine is awake, but the screen is
  /// off — e.g. display-sleep timeout with the lid open).
  public var isDisplayAsleep: Bool
  /// Whether the screen is locked (may be true independent of, and may
  /// outlast, system or display sleep — e.g. still locked after a wake).
  public var isScreenLocked: Bool

  /// All sources inactive: not suspended.
  public init(
    isSystemAsleep: Bool = false,
    isDisplayAsleep: Bool = false,
    isScreenLocked: Bool = false
  ) {
    self.isSystemAsleep = isSystemAsleep
    self.isDisplayAsleep = isDisplayAsleep
    self.isScreenLocked = isScreenLocked
  }

  /// `true` if any suspension source is active. Capture and other in-flight
  /// work should pause while this is `true`, and resume only once every
  /// source has cleared.
  public var isSuspended: Bool {
    isSystemAsleep || isDisplayAsleep || isScreenLocked
  }

  /// Returns a copy with ``isSystemAsleep`` set to `active`, leaving the
  /// other sources untouched.
  public func withSystemAsleep(_ active: Bool) -> SuspensionState {
    var copy = self
    copy.isSystemAsleep = active
    return copy
  }

  /// Returns a copy with ``isDisplayAsleep`` set to `active`, leaving the
  /// other sources untouched.
  public func withDisplayAsleep(_ active: Bool) -> SuspensionState {
    var copy = self
    copy.isDisplayAsleep = active
    return copy
  }

  /// Returns a copy with ``isScreenLocked`` set to `active`, leaving the
  /// other sources untouched.
  public func withScreenLocked(_ active: Bool) -> SuspensionState {
    var copy = self
    copy.isScreenLocked = active
    return copy
  }
}

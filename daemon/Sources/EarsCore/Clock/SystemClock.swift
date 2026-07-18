import Foundation

/// The production ``NowProviding`` conformance: reads the real system wall clock.
///
/// This is the *only* place in `EarsCore` that touches wall-clock time, and it
/// exists so every other type can stay deterministic by depending on the
/// ``NowProviding`` seam instead. Foundation is imported solely for `Date`'s
/// epoch reading — not for any file, socket, or network I/O.
public struct SystemClock: NowProviding {
  public init() {}

  public func now() -> Instant {
    Instant(secondsSinceEpoch: Date().timeIntervalSince1970)
  }
}

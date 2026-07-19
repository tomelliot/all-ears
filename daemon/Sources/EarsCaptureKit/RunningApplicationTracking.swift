import AppKit

/// A running (or just-changed) process's bundle id and pid — the shape both
/// ``SystemAudioCaptureBackend``'s per-app tap rebuild and
/// `EarsDaemonKit.AppSignalTriggerObserver`'s launch/terminate watching need,
/// so the bundle-id/PID tracking logic lives once, shared by both, rather
/// than duplicated.
public enum RunningApplicationEvent: Sendable, Hashable {
  case launched(bundleID: String, pid: pid_t)
  case terminated(bundleID: String, pid: pid_t)
}

/// Resolves a bundle id to its live PID(s), and observes app launch/
/// terminate. A bundle id can have zero, one, or several live PIDs over a
/// source's lifetime (helper processes, multiple windows/instances) — this
/// seam is what lets both consumers re-resolve that set rather than
/// snapshotting it once.
public protocol RunningApplicationTracking: Sendable {
  /// Live PIDs for every currently-running process with this bundle id.
  func livePIDs(forBundleID bundleID: String) -> [pid_t]

  /// A stream of every subsequent launch/terminate event, system-wide.
  /// Callers filter to the bundle id(s) they care about.
  func events() -> AsyncStream<RunningApplicationEvent>
}

/// The production ``RunningApplicationTracking``, backed by
/// `NSWorkspace.shared`.
public struct RealRunningApplicationTracker: RunningApplicationTracking {
  public init() {}

  public func livePIDs(forBundleID bundleID: String) -> [pid_t] {
    NSWorkspace.shared.runningApplications
      .filter { $0.bundleIdentifier == bundleID }
      .map(\.processIdentifier)
  }

  public func events() -> AsyncStream<RunningApplicationEvent> {
    AsyncStream { continuation in
      let center = NSWorkspace.shared.notificationCenter
      let launchToken = center.addObserver(
        forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: nil
      ) { notification in
        guard
          let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication,
          let bundleID = app.bundleIdentifier
        else { return }
        continuation.yield(.launched(bundleID: bundleID, pid: app.processIdentifier))
      }
      let terminateToken = center.addObserver(
        forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: nil
      ) { notification in
        guard
          let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication,
          let bundleID = app.bundleIdentifier
        else { return }
        continuation.yield(.terminated(bundleID: bundleID, pid: app.processIdentifier))
      }
      // NSObjectProtocol observer tokens aren't Sendable, but they're
      // immutable handles only ever passed back to `removeObserver` --
      // never read or mutated concurrently -- so capturing them into this
      // one-shot termination closure is safe despite the compiler's
      // conservative check.
      nonisolated(unsafe) let tokens = (launchToken, terminateToken)
      continuation.onTermination = { _ in
        center.removeObserver(tokens.0)
        center.removeObserver(tokens.1)
      }
    }
  }
}

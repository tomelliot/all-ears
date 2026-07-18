import AppKit
import EarsCore
import Foundation

/// The three actions a ``SuspensionState`` transition can trigger. Exactly
/// mirrors the "pause on suspend, resume on un-suspend, otherwise do
/// nothing" rule — see ``SuspensionTransitionPolicy``.
public enum SuspensionAction: Sendable, Hashable {
  /// No suspension source changed `isSuspended`'s value; do nothing.
  case none
  /// `isSuspended` went `false` → `true`: pause every source.
  case pause
  /// `isSuspended` went `true` → `false`: resume every source.
  case resume
}

/// The pure, exhaustively-testable decision core of ``PowerObserver``: given
/// a `SuspensionState` transition, decide whether to pause, resume, or do
/// nothing.
///
/// This is deliberately edge-triggered on ``SuspensionState/isSuspended``,
/// not on which individual source changed: `docs/specs/capture-daemon.md`
/// treats system sleep, display sleep, and screen lock as independent
/// suspension sources, so (e.g.) system-asleep flipping true while
/// display-asleep is *already* true must not re-pause (already suspended),
/// and two consecutive `willSleep` notifications — which both set
/// `isSystemAsleep = true` — must not call `pause()` twice.
public enum SuspensionTransitionPolicy {
  /// - Parameters:
  ///   - previous: The state before this notification's update.
  ///   - next: The state after this notification's update.
  /// - Returns: ``SuspensionAction/pause`` if `isSuspended` just became
  ///   `true`, ``SuspensionAction/resume`` if it just became `false`,
  ///   otherwise ``SuspensionAction/none``.
  public static func action(from previous: SuspensionState, to next: SuspensionState)
    -> SuspensionAction
  {
    switch (previous.isSuspended, next.isSuspended) {
    case (false, true): return .pause
    case (true, false): return .resume
    default: return .none
    }
  }
}

/// The shape ``PowerObserver`` needs from a capture actor: pause/resume.
/// Extracted as a protocol — rather than referencing ``CaptureActor``
/// directly everywhere — so the actor-application logic below is unit
/// testable against a fake, without depending on `CaptureActor.swift` (owned
/// by a parallel task in this same directory).
public protocol SuspendablePauseResume: Sendable {
  func pause() async throws
  func resume() async throws
}

extension CaptureActor: SuspendablePauseResume {}

/// Watches macOS power/idle notifications — system sleep/wake, display
/// sleep/wake, and screen lock/unlock — and pauses/resumes every capture
/// actor it's given whenever ``SuspensionState/isSuspended`` transitions, per
/// `docs/specs/capture-daemon.md`'s "Power/idle awareness" requirement.
///
/// ## Independent suspension sources
///
/// System sleep, display sleep, and screen lock are tracked independently
/// (``SuspensionState``'s existing semantics): a wake from system sleep while
/// the screen is still locked must keep every source paused, since
/// `isScreenLocked` still holds. Each notification updates exactly one of
/// the three flags; ``SuspensionTransitionPolicy`` then decides whether the
/// combined `isSuspended` value actually flipped.
///
/// ## Screen lock via `DistributedNotificationCenter`
///
/// `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` are the
/// conventional (if not officially documented) mechanism for screen lock
/// state, posted on `DistributedNotificationCenter.default()` rather than
/// `NSWorkspace`'s notification center.
///
/// ## Testability split
///
/// The notification wiring itself (``startObserving()``/``stopObserving()``)
/// is thin, behavior-verified-by-inspection glue (tier-2 per
/// `docs/engineering-practices.md`) — it does nothing but translate an OS
/// notification into a call to ``update(_:)``. All of the actual decision
/// logic is the pure ``SuspensionTransitionPolicy``, and the
/// state-update-then-maybe-act sequencing in ``update(_:)`` is itself unit
/// tested via the ``init(pausables:)`` seam, with fake
/// ``SuspendablePauseResume``s standing in for real `CaptureActor`s.
public actor PowerObserver {
  private var state = SuspensionState()
  private let pausables: [SourceID: any SuspendablePauseResume]
  private var workspaceTokens: [NSObjectProtocol] = []
  private var distributedTokens: [NSObjectProtocol] = []

  /// - Parameter captureActors: Every source's capture actor, paused/resumed
  ///   together on each suspension transition.
  public init(captureActors: [SourceID: CaptureActor]) {
    self.pausables = captureActors.mapValues { $0 as any SuspendablePauseResume }
  }

  /// Test-only seam: construct directly over ``SuspendablePauseResume`` so
  /// unit tests can inject fakes without a real `CaptureActor`.
  init(pausables: [SourceID: any SuspendablePauseResume]) {
    self.pausables = pausables
  }

  /// Start observing sleep/wake/lock notifications. Idempotent-in-spirit but
  /// not idempotent-enforced: call once per instance (call ``stopObserving()``
  /// first to re-observe).
  public func startObserving() {
    let workspace = NSWorkspace.shared.notificationCenter
    let distributed = DistributedNotificationCenter.default()

    workspaceTokens.append(
      workspace.addObserver(
        forName: NSWorkspace.willSleepNotification, object: nil, queue: nil
      ) { [weak self] _ in
        Task { await self?.update { $0.withSystemAsleep(true) } }
      })
    workspaceTokens.append(
      workspace.addObserver(
        forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
      ) { [weak self] _ in
        Task { await self?.update { $0.withSystemAsleep(false) } }
      })
    workspaceTokens.append(
      workspace.addObserver(
        forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: nil
      ) { [weak self] _ in
        Task { await self?.update { $0.withDisplayAsleep(true) } }
      })
    workspaceTokens.append(
      workspace.addObserver(
        forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: nil
      ) { [weak self] _ in
        Task { await self?.update { $0.withDisplayAsleep(false) } }
      })
    distributedTokens.append(
      distributed.addObserver(
        forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: nil
      ) { [weak self] _ in
        Task { await self?.update { $0.withScreenLocked(true) } }
      })
    distributedTokens.append(
      distributed.addObserver(
        forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: nil
      ) { [weak self] _ in
        Task { await self?.update { $0.withScreenLocked(false) } }
      })
  }

  /// Stop observing and release every registered token.
  public func stopObserving() {
    let workspace = NSWorkspace.shared.notificationCenter
    for token in workspaceTokens { workspace.removeObserver(token) }
    workspaceTokens.removeAll()

    let distributed = DistributedNotificationCenter.default()
    for token in distributedTokens { distributed.removeObserver(token) }
    distributedTokens.removeAll()
  }

  /// Applies one suspension-source update, then acts per
  /// ``SuspensionTransitionPolicy``. The seam every notification handler and
  /// every unit test goes through.
  func update(_ transform: (SuspensionState) -> SuspensionState) async {
    let previous = state
    let next = transform(previous)
    state = next
    switch SuspensionTransitionPolicy.action(from: previous, to: next) {
    case .pause:
      await forEachPausable { try await $0.pause() }
    case .resume:
      await forEachPausable { try await $0.resume() }
    case .none:
      break
    }
  }

  /// Current suspension state, for tests/inspection.
  var currentState: SuspensionState { state }

  private func forEachPausable(_ body: (any SuspendablePauseResume) async throws -> Void) async {
    for pausable in pausables.values {
      try? await body(pausable)
    }
  }
}

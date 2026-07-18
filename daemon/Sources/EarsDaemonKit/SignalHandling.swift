import Dispatch
import EarsCore
import Foundation

/// The shape ``ShutdownCoordinator`` needs from a capture actor: a graceful
/// `stop()`. Extracted as a protocol -- rather than referencing
/// ``CaptureActor`` directly -- so ``ShutdownCoordinator``'s orchestration
/// logic is unit testable against fakes, without depending on
/// `CaptureActor.swift` (owned by a parallel task in this same directory).
public protocol Stoppable: Sendable {
  func stop() async
}

extension CaptureActor: Stoppable {}

/// Orchestrates graceful shutdown, per `docs/specs/capture-daemon.md`'s
/// "`SIGTERM` = graceful" requirement: calls `stop()` -- which flushes each
/// source's in-progress chunk and indexes it, per ``CaptureActor/stop()``'s
/// contract -- on every registered actor before the process is allowed to
/// exit.
///
/// This is the async orchestration only; wiring it to the actual `SIGTERM`
/// signal is ``SignalHandling``'s job. Kept separate so the "call stop on
/// every actor, once" logic is testable with fakes, with no real OS signal
/// involved.
public actor ShutdownCoordinator {
  private let stoppables: [any Stoppable]
  private var hasShutDown = false

  /// - Parameter captureActors: Every source's capture actor, stopped on
  ///   shutdown.
  public init(captureActors: [CaptureActor]) {
    self.stoppables = captureActors
  }

  /// Test-only seam: construct directly over ``Stoppable`` so unit tests can
  /// inject fakes without real `CaptureActor`s.
  init(stoppables: [any Stoppable]) {
    self.stoppables = stoppables
  }

  /// Calls `stop()` on every registered actor, in registration order, then
  /// returns. Idempotent: a second call is a no-op (no actor is stopped
  /// twice), matching `stop()`'s own idempotency so a duplicate `SIGTERM`
  /// during shutdown can't double-flush.
  public func shutdown() async {
    guard !hasShutDown else { return }
    hasShutDown = true
    for stoppable in stoppables {
      await stoppable.stop()
    }
  }
}

/// Installs OS signal handlers for the daemon's lifecycle. Deliberately thin
/// -- tier-2 glue per `docs/engineering-practices.md` -- translating a raw
/// `SIGTERM` into an async call to ``ShutdownCoordinator/shutdown()``; all of
/// the actual orchestration logic lives there, where it's unit tested.
public enum SignalHandling {
  /// Installs a `SIGTERM` handler that calls `onSignal` exactly once per
  /// delivery.
  ///
  /// Uses `DispatchSourceSignal`, the standard modern mechanism for
  /// composing OS signals with async Swift code: the default `SIGTERM`
  /// disposition is silenced first (`signal(SIGTERM, SIG_IGN)`) so the
  /// process doesn't also take the default terminate-immediately action --
  /// only this dispatch source's handler runs.
  ///
  /// - Parameters:
  ///   - queue: Where `onSignal` runs. Defaults to a dedicated background
  ///     queue rather than `.main`, since `earsd` has no run loop guarantee
  ///     on its main thread.
  ///   - onSignal: Called on every `SIGTERM` delivery. Typically wraps a
  ///     `Task { await shutdownCoordinator.shutdown(); exit(0) }`.
  /// - Returns: The `DispatchSourceSignal`. The caller must keep a strong
  ///   reference to it for the lifetime of the process -- a deallocated
  ///   dispatch source stops firing.
  @discardableResult
  public static func installSIGTERMHandler(
    queue: DispatchQueue = DispatchQueue(label: "net.tomelliot.ears.earsd.sigterm"),
    onSignal: @escaping @Sendable () -> Void
  ) -> DispatchSourceSignal {
    signal(SIGTERM, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
    source.setEventHandler(handler: onSignal)
    source.resume()
    return source
  }
}

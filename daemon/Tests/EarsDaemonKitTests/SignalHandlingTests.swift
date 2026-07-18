import Testing

@testable import EarsDaemonKit

/// Records `stop()` calls for ``ShutdownCoordinator`` tests below, so both
/// "was every actor stopped" and "in what order" are observable.
private actor CallLog {
  private(set) var calls: [String] = []

  func record(_ name: String) {
    calls.append(name)
  }
}

private actor FakeStoppable: Stoppable {
  private let name: String
  private let log: CallLog
  private(set) var stopCallCount = 0

  init(name: String, log: CallLog) {
    self.name = name
    self.log = log
  }

  func stop() async {
    stopCallCount += 1
    await log.record(name)
  }
}

/// ``ShutdownCoordinator/shutdown()`` orchestration tests -- the "given a
/// shutdown signal, call stop on every actor in some order, then signal
/// completion" logic, driven with fake ``Stoppable``s rather than a real
/// `SIGTERM` (that OS-signal wiring is ``SignalHandling``'s job, thin tier-2
/// glue per `docs/engineering-practices.md`, verified by inspection).
@Suite("ShutdownCoordinator")
struct ShutdownCoordinatorTests {
  @Test("shutdown stops every registered actor, in registration order")
  func stopsEveryActor() async {
    let log = CallLog()
    let mic = FakeStoppable(name: "mic", log: log)
    let system = FakeStoppable(name: "system", log: log)
    let coordinator = ShutdownCoordinator(stoppables: [mic, system])

    await coordinator.shutdown()

    #expect(await mic.stopCallCount == 1)
    #expect(await system.stopCallCount == 1)
    #expect(await log.calls == ["mic", "system"])
  }

  @Test("shutdown with no registered actors returns without error")
  func shutdownWithNoActors() async {
    let coordinator = ShutdownCoordinator(stoppables: [])

    await coordinator.shutdown()
  }

  @Test("a second shutdown call does not stop any actor again")
  func shutdownIsIdempotent() async {
    let log = CallLog()
    let mic = FakeStoppable(name: "mic", log: log)
    let coordinator = ShutdownCoordinator(stoppables: [mic])

    await coordinator.shutdown()
    await coordinator.shutdown()

    #expect(await mic.stopCallCount == 1)
    #expect(await log.calls == ["mic"])
  }
}

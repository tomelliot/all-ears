import EarsCore
import Testing

@testable import EarsDaemonKit

/// Exhaustive coverage of ``SuspensionTransitionPolicy``'s pure decision
/// logic (tier-0 per `docs/engineering-practices.md`): every combination of
/// "was suspended" / "is suspended" the three independent sources
/// (``SuspensionState/isSystemAsleep``, `isDisplayAsleep`, `isScreenLocked`)
/// can produce.
@Suite("SuspensionTransitionPolicy")
struct SuspensionTransitionPolicyTests {
  private static let awake = SuspensionState()
  private static let asleep = SuspensionState(isSystemAsleep: true)
  private static let displayAsleep = SuspensionState(isDisplayAsleep: true)
  private static let locked = SuspensionState(isScreenLocked: true)
  private static let asleepAndLocked = SuspensionState(isSystemAsleep: true, isScreenLocked: true)
  private static let allSuspended = SuspensionState(
    isSystemAsleep: true, isDisplayAsleep: true, isScreenLocked: true)

  @Test(
    "transitions",
    arguments: [
      // Not suspended -> not suspended: never acts, regardless of which
      // (still-inactive) source nominally changed.
      (awake, awake, SuspensionAction.none),

      // Not suspended -> suspended, one source at a time: pause.
      (awake, asleep, SuspensionAction.pause),
      (awake, displayAsleep, SuspensionAction.pause),
      (awake, locked, SuspensionAction.pause),

      // Suspended -> not suspended, one source at a time: resume.
      (asleep, awake, SuspensionAction.resume),
      (displayAsleep, awake, SuspensionAction.resume),
      (locked, awake, SuspensionAction.resume),

      // Suspended -> still suspended, but via a *different* source: no
      // second pause. E.g. system asleep, then the screen also locks while
      // still asleep.
      (asleep, asleepAndLocked, SuspensionAction.none),
      (locked, asleepAndLocked, SuspensionAction.none),
      (allSuspended, asleepAndLocked, SuspensionAction.none),

      // Suspended -> still suspended, identical state: the "two willSleep
      // notifications in a row" case -- must not pause twice.
      (asleep, asleep, SuspensionAction.none),
      (allSuspended, allSuspended, SuspensionAction.none),

      // One suspension source clears but another still holds: stays
      // suspended, so no resume yet (e.g. system wakes, screen still
      // locked).
      (asleepAndLocked, locked, SuspensionAction.none),
      (allSuspended, asleep, SuspensionAction.none),
    ] as [(SuspensionState, SuspensionState, SuspensionAction)]
  )
  func transitions(previous: SuspensionState, next: SuspensionState, expected: SuspensionAction) {
    #expect(SuspensionTransitionPolicy.action(from: previous, to: next) == expected)
  }
}

/// A fake ``SuspendablePauseResume`` that counts calls, for
/// ``PowerObserver``'s edge-triggering behavior tests below.
private actor FakePauseResume: SuspendablePauseResume {
  private(set) var pauseCount = 0
  private(set) var resumeCount = 0

  func pause() async throws {
    pauseCount += 1
  }

  func resume() async throws {
    resumeCount += 1
  }
}

/// ``PowerObserver/update(_:)`` integration tests: the actor-level
/// state-update-then-maybe-act sequencing, driven through the
/// ``PowerObserver/init(pausables:)`` fake seam rather than real
/// `NSWorkspace`/`DistributedNotificationCenter` notifications (that wiring
/// is thin, behavior-verified-by-inspection tier-2 glue per
/// `docs/engineering-practices.md`).
@Suite("PowerObserver")
struct PowerObserverTests {
  @Test("a single suspension source going active pauses every actor exactly once")
  func pausesOnFirstSuspend() async {
    let fake = FakePauseResume()
    let observer = PowerObserver(pausables: ["mic": fake])

    await observer.update { $0.withSystemAsleep(true) }

    #expect(await fake.pauseCount == 1)
    #expect(await fake.resumeCount == 0)
  }

  @Test("a repeated notification for the same source does not pause twice")
  func doesNotDoublePauseOnRepeatedNotification() async {
    let fake = FakePauseResume()
    let observer = PowerObserver(pausables: ["mic": fake])

    await observer.update { $0.withSystemAsleep(true) }
    await observer.update { $0.withSystemAsleep(true) }

    #expect(await fake.pauseCount == 1)
  }

  @Test("a second independent suspension source does not pause again while already suspended")
  func doesNotDoublePauseAcrossIndependentSources() async {
    let fake = FakePauseResume()
    let observer = PowerObserver(pausables: ["mic": fake])

    await observer.update { $0.withSystemAsleep(true) }
    await observer.update { $0.withScreenLocked(true) }

    #expect(await fake.pauseCount == 1)
  }

  @Test("clearing one suspension source while another still holds does not resume")
  func doesNotResumeWhileAnotherSourceStillSuspended() async {
    let fake = FakePauseResume()
    let observer = PowerObserver(pausables: ["mic": fake])

    await observer.update { $0.withSystemAsleep(true) }
    await observer.update { $0.withScreenLocked(true) }
    await observer.update { $0.withSystemAsleep(false) }

    #expect(await fake.resumeCount == 0)
  }

  @Test("clearing the last active suspension source resumes every actor exactly once")
  func resumesOnceEverySourceClears() async {
    let fake = FakePauseResume()
    let observer = PowerObserver(pausables: ["mic": fake])

    await observer.update { $0.withSystemAsleep(true) }
    await observer.update { $0.withScreenLocked(true) }
    await observer.update { $0.withSystemAsleep(false) }
    await observer.update { $0.withScreenLocked(false) }

    #expect(await fake.pauseCount == 1)
    #expect(await fake.resumeCount == 1)
  }

  @Test("every registered actor is paused and resumed")
  func actsOnEveryRegisteredActor() async {
    let mic = FakePauseResume()
    let system = FakePauseResume()
    let observer = PowerObserver(pausables: ["mic": mic, "system": system])

    await observer.update { $0.withSystemAsleep(true) }
    await observer.update { $0.withSystemAsleep(false) }

    #expect(await mic.pauseCount == 1)
    #expect(await mic.resumeCount == 1)
    #expect(await system.pauseCount == 1)
    #expect(await system.resumeCount == 1)
  }
}

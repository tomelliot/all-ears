import EarsCore
import Testing

@testable import EarsCaptureKit

@Suite("ExponentialBackoff")
struct ExponentialBackoffTests {
  @Test("attempt 0 is the base delay")
  func firstAttemptIsBase() {
    let backoff = ExponentialBackoff(base: .milliseconds(100), cap: .seconds(5))
    #expect(backoff.delay(forAttempt: 0) == .milliseconds(100))
  }

  @Test("doubles each attempt until the cap")
  func doublesUntilCap() {
    let backoff = ExponentialBackoff(base: .milliseconds(100), cap: .seconds(5))
    #expect(backoff.delay(forAttempt: 1) == .milliseconds(200))
    #expect(backoff.delay(forAttempt: 2) == .milliseconds(400))
    #expect(backoff.delay(forAttempt: 3) == .milliseconds(800))
    #expect(backoff.delay(forAttempt: 4) == .milliseconds(1600))
    #expect(backoff.delay(forAttempt: 5) == .milliseconds(3200))
  }

  @Test("clamps to the cap once exceeded and stays there")
  func clampsToCap() {
    let backoff = ExponentialBackoff(base: .milliseconds(100), cap: .seconds(5))
    #expect(backoff.delay(forAttempt: 6) == .seconds(5))  // 6400ms -> capped
    #expect(backoff.delay(forAttempt: 20) == .seconds(5))
  }

  @Test("a base already above the cap is clamped")
  func baseAboveCapClamped() {
    let backoff = ExponentialBackoff(base: .seconds(10), cap: .seconds(5))
    #expect(backoff.delay(forAttempt: 0) == .seconds(5))
  }
}

@Suite("StallDetector")
struct StallDetectorTests {
  private func instant(_ s: Double) -> Instant { Instant(secondsSinceEpoch: s) }

  @Test("not stalled while callbacks keep arriving within the threshold")
  func liveIsNotStalled() {
    let detector = StallDetector(threshold: 5)
    #expect(
      !detector.isStalled(
        lastActivity: instant(100), startedAt: instant(90), now: instant(103)))
  }

  @Test("stalled once the threshold elapses since the last callback")
  func silenceIsStalled() {
    let detector = StallDetector(threshold: 5)
    #expect(
      detector.isStalled(
        lastActivity: instant(100), startedAt: instant(90), now: instant(106)))
  }

  @Test("a never-firing engine is judged against its start time")
  func neverFiredJudgedAgainstStart() {
    let detector = StallDetector(threshold: 5)
    #expect(
      !detector.isStalled(lastActivity: nil, startedAt: instant(100), now: instant(104)))
    #expect(
      detector.isStalled(lastActivity: nil, startedAt: instant(100), now: instant(105)))
  }
}

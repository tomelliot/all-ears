import EarsCore
import Testing

@testable import EarsDataStore

/// Pure unit tests for ``StartupGapDetector`` -- tier-0 per
/// `docs/engineering-practices.md`, no I/O and no wall-clock reads (`now`
/// is always an injected literal ``Instant``).
@Suite("StartupGapDetector")
struct StartupGapDetectorTests {
  @Test("lastKnownEnd is nil for an empty index (brand-new source)")
  func lastKnownEndNilWhenEmpty() {
    #expect(StartupGapDetector.lastKnownEnd(in: []) == nil)
  }

  @Test("lastKnownEnd takes the latest end across chunk, vad, and gap events")
  func lastKnownEndAcrossEventKinds() {
    let events: [IndexEvent] = [
      .chunk(
        start: Instant(secondsSinceEpoch: 0), end: Instant(secondsSinceEpoch: 30), file: "a",
        frames: 1),
      .vad(
        state: .speech, start: Instant(secondsSinceEpoch: 10), end: Instant(secondsSinceEpoch: 20)),
      .gap(
        start: Instant(secondsSinceEpoch: 30), end: Instant(secondsSinceEpoch: 45),
        reason: "device_lost"),
    ]
    #expect(StartupGapDetector.lastKnownEnd(in: events) == Instant(secondsSinceEpoch: 45))
  }

  @Test("evict events don't count as coverage")
  func evictDoesNotCountAsCoverage() {
    let events: [IndexEvent] = [
      .chunk(
        start: Instant(secondsSinceEpoch: 0), end: Instant(secondsSinceEpoch: 30), file: "a",
        frames: 1),
      .evict(file: "a", start: Instant(secondsSinceEpoch: 1_000)),
    ]
    #expect(StartupGapDetector.lastKnownEnd(in: events) == Instant(secondsSinceEpoch: 30))
  }

  @Test("no gap event when there's no prior coverage")
  func noGapWithNoPriorCoverage() {
    let event = StartupGapDetector.gapEvent(
      afterLastKnownEnd: nil, now: Instant(secondsSinceEpoch: 100))
    #expect(event == nil)
  }

  @Test("a gap event covers [lastKnownEnd, now) when time has passed")
  func gapCoversInterval() {
    let event = StartupGapDetector.gapEvent(
      afterLastKnownEnd: Instant(secondsSinceEpoch: 100), now: Instant(secondsSinceEpoch: 160))
    #expect(
      event
        == .gap(
          start: Instant(secondsSinceEpoch: 100), end: Instant(secondsSinceEpoch: 160),
          reason: "daemon_restart"))
  }

  @Test("no gap event when now equals lastKnownEnd (instantaneous restart)")
  func noGapWhenNowEqualsLastKnownEnd() {
    let event = StartupGapDetector.gapEvent(
      afterLastKnownEnd: Instant(secondsSinceEpoch: 100), now: Instant(secondsSinceEpoch: 100))
    #expect(event == nil)
  }

  @Test("no gap event when now precedes lastKnownEnd (clock anomaly)")
  func noGapWhenNowPrecedesLastKnownEnd() {
    let event = StartupGapDetector.gapEvent(
      afterLastKnownEnd: Instant(secondsSinceEpoch: 100), now: Instant(secondsSinceEpoch: 50))
    #expect(event == nil)
  }

  @Test("a custom reason is threaded through")
  func customReason() {
    let event = StartupGapDetector.gapEvent(
      afterLastKnownEnd: Instant(secondsSinceEpoch: 100), now: Instant(secondsSinceEpoch: 160),
      reason: "device_lost")
    #expect(
      event
        == .gap(
          start: Instant(secondsSinceEpoch: 100), end: Instant(secondsSinceEpoch: 160),
          reason: "device_lost"))
  }
}

import EarsCore
import Synchronization
import Testing

@testable import EarsDaemonKit

/// Tier-0 tests for ``EventBus``: the late-binding bridge between event
/// producers and the transports' fan-out, and — in v2 — the owner of the
/// monotonic state revision. No sockets.
@Suite("EventBus")
struct EventBusTests {
  private func sampleSession() -> SessionSummary {
    SessionSummary(
      SessionDescriptor(
        schema: 1, id: "2026-07-17T10-30-00Z_s", slug: "s", sources: ["mic"],
        start: Instant(secondsSinceEpoch: 1), state: .open, trigger: .manual))
  }

  /// Waits until the drain task has delivered `count` frames.
  private func waitForFrames(
    _ recorded: Mutex<[EventFrame]>, count: Int
  ) async {
    for _ in 0..<1_000 {
      if recorded.withLock({ $0.count }) >= count { return }
      await Task.yield()
    }
  }

  @Test("publish with no sink attached drops the event silently")
  func publishUnattachedDrops() async {
    let bus = EventBus()
    // Must neither crash nor hang; nothing observable to assert beyond that.
    await bus.publish(.session(sampleSession()))
  }

  @Test("state events get contiguous revisions; telemetry events stay untagged")
  func revisionClasses() async {
    let bus = EventBus()
    let recorded = Mutex<[EventFrame]>([])
    await bus.attach { frame in recorded.withLock { $0.append(frame) } }

    let first = await bus.publish(.session(sampleSession()))
    let telemetry = await bus.publish(
      .vad(source: "mic", state: .speech, t: Instant(secondsSinceEpoch: 1)))
    let second = await bus.publish(.source(id: "mic", state: .paused))

    #expect(first == 1)
    #expect(telemetry == nil)
    #expect(second == 2)
    #expect(await bus.currentRev() == 2)

    await waitForFrames(recorded, count: 3)
    let frames = recorded.withLock { $0 }
    #expect(frames.count == 3)
    #expect(frames[0].rev == 1)
    #expect(frames[1].rev == nil)
    #expect(frames[2].rev == 2)
  }

  @Test("publishState hands the assigned rev to the payload builder")
  func publishStateEmbedsRev() async {
    let bus = EventBus()
    let recorded = Mutex<[EventFrame]>([])
    await bus.attach { frame in recorded.withLock { $0.append(frame) } }

    let meeting = Meeting(
      id: "m1", title: "t", state: .active, started: Instant(secondsSinceEpoch: 1))
    let rev = await bus.publishState { rev in
      var stamped = meeting
      stamped.rev = rev
      return .meeting(stamped)
    }

    #expect(rev == 1)
    await waitForFrames(recorded, count: 1)
    let frames = recorded.withLock { $0 }
    guard case .meeting(let published)? = frames.first?.event else {
      Issue.record("expected a meeting frame")
      return
    }
    #expect(published.rev == 1)
    #expect(frames.first?.rev == 1)
  }

  @Test("detach stops forwarding; a later attach resumes (revs keep counting)")
  func detachStopsForwarding() async {
    let bus = EventBus()
    let recorded = Mutex<[EventFrame]>([])
    let sink: EventBus.FrameSink = { frame in recorded.withLock { $0.append(frame) } }

    await bus.attach(sink)
    await bus.publish(.source(id: "mic", state: .capturing))
    await waitForFrames(recorded, count: 1)
    await bus.detach()
    await bus.publish(.source(id: "mic", state: .paused))  // dropped, still revs
    await bus.attach(sink)
    await bus.publish(.source(id: "mic", state: .capturing))
    await waitForFrames(recorded, count: 2)

    let frames = recorded.withLock { $0 }
    #expect(frames.count == 2)
    // The dropped event still consumed rev 2 — a late subscriber's snapshot
    // simply starts at the current revision.
    #expect(frames.map(\.rev) == [1, 3])
  }
}

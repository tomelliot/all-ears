import EarsCore
import Synchronization
import Testing

@testable import EarsDaemonKit

/// Tier-0 tests for ``EventBus``, the late-binding bridge between event
/// producers and the socket server's pub/sub fan-out — pure attach/detach/
/// forward logic, no sockets.
@Suite("EventBus")
struct EventBusTests {
  @Test("publish with no sink attached drops the event silently")
  func publishUnattachedDrops() async {
    let bus = EventBus()
    // Must neither crash nor hang; nothing observable to assert beyond that.
    await bus.publish(.session(id: "s", state: .open))
  }

  @Test("publish forwards to the attached sink in order")
  func publishForwards() async {
    let bus = EventBus()
    let recorded = Mutex<[EarsEvent]>([])
    await bus.attach { event in recorded.withLock { $0.append(event) } }

    await bus.publish(.session(id: "s", state: .open))
    await bus.publish(.vad(source: "mic", state: .speech, t: Instant(secondsSinceEpoch: 1)))

    #expect(
      recorded.withLock { $0 } == [
        .session(id: "s", state: .open),
        .vad(source: "mic", state: .speech, t: Instant(secondsSinceEpoch: 1)),
      ])
  }

  @Test("detach stops forwarding; a later attach resumes it")
  func detachStopsForwarding() async {
    let bus = EventBus()
    let recorded = Mutex<[EarsEvent]>([])
    let sink: EventSink = { event in recorded.withLock { $0.append(event) } }

    await bus.attach(sink)
    await bus.publish(.session(id: "before", state: .open))
    await bus.detach()
    await bus.publish(.session(id: "dropped", state: .open))
    await bus.attach(sink)
    await bus.publish(.session(id: "after", state: .open))

    #expect(
      recorded.withLock { $0 } == [
        .session(id: "before", state: .open),
        .session(id: "after", state: .open),
      ])
  }
}

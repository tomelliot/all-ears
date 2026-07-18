import Testing

@testable import EarsCore

@Suite("SessionDescriptor")
struct SessionDescriptorTests {
  @Test("exposes a range only once closed")
  func rangeWhenClosed() {
    let open = SessionDescriptor(
      schema: 1,
      id: "2026-07-17T10-30-00Z_standup",
      slug: "standup",
      sources: ["mic", "app:us.zoom.xos"],
      start: Instant(secondsSinceEpoch: 100),
      end: nil,
      state: .open,
      trigger: .manual
    )
    #expect(open.range == nil)

    var closed = open
    closed.end = Instant(secondsSinceEpoch: 160)
    closed.state = .closed
    #expect(
      closed.range
        == TimeRange(
          start: Instant(secondsSinceEpoch: 100),
          end: Instant(secondsSinceEpoch: 160)
        ))
    #expect(closed.range?.duration == 60)
  }
}

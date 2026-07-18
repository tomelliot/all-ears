import EarsCore
import Testing

@testable import EarsIPC

@Suite("EventFilter")
struct EventFilterTests {
  private let vadMic = EarsEvent.vad(
    source: "mic", state: .speech, t: Instant(secondsSinceEpoch: 1))
  private let vadZoom = EarsEvent.vad(
    source: "app:us.zoom.xos", state: .silence, t: Instant(secondsSinceEpoch: 2))
  private let sessionEvent = EarsEvent.session(id: "s1", state: .open)
  private let segmentEvent = EarsEvent.segment(
    session: "s1", speaker: "You", start: 0, end: 1, text: "hi")

  @Test("kind and source are derived from the event")
  func derivedKindAndSource() {
    #expect(vadMic.kind == .vad)
    #expect(vadMic.source == SourceID("mic"))
    #expect(sessionEvent.kind == .session)
    #expect(sessionEvent.source == nil)
    #expect(segmentEvent.kind == .segment)
    #expect(segmentEvent.source == nil)
  }

  @Test("empty events and sources matches everything")
  func emptyFilterMatchesAll() {
    let sub = SubscribeRequest(events: [], sources: [])
    #expect(EventFilter.matches(vadMic, sub))
    #expect(EventFilter.matches(sessionEvent, sub))
    #expect(EventFilter.matches(segmentEvent, sub))
  }

  @Test("event kind not in the filter is excluded")
  func kindFilterExcludes() {
    let sub = SubscribeRequest(events: [.session], sources: [])
    #expect(!EventFilter.matches(vadMic, sub))
    #expect(EventFilter.matches(sessionEvent, sub))
    #expect(!EventFilter.matches(segmentEvent, sub))
  }

  @Test("source filter excludes a sourced event whose source is not listed")
  func sourceFilterExcludes() {
    let sub = SubscribeRequest(events: [], sources: ["mic"])
    #expect(EventFilter.matches(vadMic, sub))
    #expect(!EventFilter.matches(vadZoom, sub))
  }

  @Test("source filter passes sourceless events regardless of the source list")
  func sourcelessEventsPassSourceFilter() {
    let sub = SubscribeRequest(events: [], sources: ["mic"])
    #expect(EventFilter.matches(sessionEvent, sub))
    #expect(EventFilter.matches(segmentEvent, sub))
  }

  @Test("kind and source filters both apply")
  func combinedFilter() {
    let sub = SubscribeRequest(events: [.vad], sources: ["mic"])
    #expect(EventFilter.matches(vadMic, sub))
    #expect(!EventFilter.matches(vadZoom, sub))
    #expect(!EventFilter.matches(sessionEvent, sub))
  }
}

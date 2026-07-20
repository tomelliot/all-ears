import EarsCore
import Testing

@testable import EarsIPC

@Suite("EventFilter (v2)")
struct EventFilterTests {
  private let vadMic = EventFrame(
    event: .vad(source: "mic", state: .speech, t: Instant(secondsSinceEpoch: 1)))
  private let vadZoom = EventFrame(
    event: .vad(source: "app:us.zoom.xos", state: .silence, t: Instant(secondsSinceEpoch: 2)))
  private let segmentFrame = EventFrame(
    event: .segment(
      SegmentPublishParams(session: "s1", speaker: "You", start: 0, end: 1, text: "hi")))
  private let jobFrame = EventFrame(
    event: .job(JobPublishParams(job: "j1", kind: "transcribe", state: .running)))
  private let sourceFrame = EventFrame(event: .source(id: "mic", state: .paused), rev: 1)
  private let meetingFrame = EventFrame(
    event: .meeting(
      Meeting(id: "m1", title: "t", state: .active, started: Instant(secondsSinceEpoch: 1))),
    rev: 2)

  @Test("empty events and sources matches everything")
  func emptyFilterMatchesAll() {
    let sub = SubscribeParams()
    #expect(EventFilter.matches(vadMic, sub))
    #expect(EventFilter.matches(segmentFrame, sub))
    #expect(EventFilter.matches(jobFrame, sub))
    #expect(EventFilter.matches(sourceFrame, sub))
  }

  @Test("state frames are always delivered — the filters never apply to them")
  func stateAlwaysDelivered() {
    let sub = SubscribeParams(events: [.vad], sources: ["app:us.zoom.xos"])
    #expect(EventFilter.matches(sourceFrame, sub))
    #expect(EventFilter.matches(meetingFrame, sub))
  }

  @Test("a telemetry kind not in the filter is excluded")
  func kindFilterExcludes() {
    let sub = SubscribeParams(events: [.segment])
    #expect(!EventFilter.matches(vadMic, sub))
    #expect(EventFilter.matches(segmentFrame, sub))
    #expect(!EventFilter.matches(jobFrame, sub))
  }

  @Test("source filter excludes a sourced telemetry frame whose source is not listed")
  func sourceFilterExcludes() {
    let sub = SubscribeParams(sources: ["mic"])
    #expect(EventFilter.matches(vadMic, sub))
    #expect(!EventFilter.matches(vadZoom, sub))
  }

  @Test("source filter passes sourceless telemetry regardless of the source list")
  func sourcelessTelemetryPassesSourceFilter() {
    let sub = SubscribeParams(sources: ["mic"])
    #expect(EventFilter.matches(segmentFrame, sub))
    #expect(EventFilter.matches(jobFrame, sub))
  }

  @Test("kind and source filters both apply to telemetry")
  func combinedFilter() {
    let sub = SubscribeParams(events: [.vad], sources: ["mic"])
    #expect(EventFilter.matches(vadMic, sub))
    #expect(!EventFilter.matches(vadZoom, sub))
    #expect(!EventFilter.matches(segmentFrame, sub))
  }
}

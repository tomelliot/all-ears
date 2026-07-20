import Foundation
import Testing

@testable import EarsCore

/// Covers the v2 request envelope (`{"id", "method", "params"}`) and its
/// typed param decoding — `docs/product/specs/control-protocol.md`'s wire
/// envelope. Cross-codec conformance against the shared golden fixtures
/// lives in `ControlProtocolV2FixtureTests`.
@Suite("ControlRequestFrame")
struct ControlRequestFrameTests {
  private let base = Instant(secondsSinceEpoch: 1_784_284_200)  // 2026-07-17T10:30:00Z

  private func decode(_ json: String) throws -> ControlRequestFrame {
    try JSONDecoder().decode(ControlRequestFrame.self, from: Data(json.utf8))
  }

  private func roundTrip(_ frame: ControlRequestFrame) throws -> ControlRequestFrame {
    let data = try JSONEncoder().encode(frame)
    return try JSONDecoder().decode(ControlRequestFrame.self, from: data)
  }

  @Test("decodes hello into its own case, id echoed")
  func decodesHello() throws {
    let json = """
      {"id":0,"method":"hello","params":{"protocol":2,"client":"browser-extension/0.4"}}
      """
    let frame = try decode(json)
    guard case .hello(let id, let params) = frame else {
      Issue.record("expected .hello, got \(frame)")
      return
    }
    #expect(id == .int(0))
    #expect(params == HelloParams(protocolVersion: 2, client: "browser-extension/0.4"))
  }

  @Test("string and integer request ids round-trip verbatim")
  func requestIDs() throws {
    let intFrame = try roundTrip(.call(id: .int(7), call: .status))
    #expect(intFrame.id == .int(7))
    let stringFrame = try roundTrip(.call(id: .string("req-77"), call: .meetingList))
    #expect(stringFrame.id == .string("req-77"))
  }

  @Test(
    "decodes params-less methods",
    arguments: [
      ("status", ControlCall.status),
      ("meeting.list", ControlCall.meetingList),
      ("session.list", ControlCall.sessionList),
      ("sources.list", ControlCall.sourcesList),
      ("flush", ControlCall.flush),
    ])
  func decodesParamsless(method: String, expected: ControlCall) throws {
    let frame = try decode("{\"id\":1,\"method\":\"\(method)\"}")
    #expect(frame == .call(id: .int(1), call: expected))
  }

  @Test("decodes meeting.start with identity, sources, and trigger")
  func decodesMeetingStart() throws {
    let json = """
      {"id":3,"method":"meeting.start","params":{"platform":"meet","external_id":"abc",
       "title":"Weekly sync","sources":["mic"],"trigger":"browser-extension"}}
      """
    let frame = try decode(json)
    let expected = MeetingStartParams(
      platform: "meet", externalID: "abc", title: "Weekly sync", sources: ["mic"],
      trigger: .browserExtension)
    #expect(frame == .call(id: .int(3), call: .meetingStart(expected)))
    #expect(expected.identity == MeetingIdentity(platform: "meet", externalID: "abc"))
  }

  @Test("meeting.start with no identity params is a manual meeting")
  func manualMeetingStart() throws {
    let frame = try decode("{\"id\":4,\"method\":\"meeting.start\"}")
    guard case .call(_, .meetingStart(let params)) = frame else {
      Issue.record("expected meetingStart")
      return
    }
    #expect(params.identity == nil)
    #expect(params.sources.isEmpty)
  }

  @Test("decodes the meeting-ref verbs")
  func meetingRefVerbs() throws {
    #expect(
      try decode("{\"id\":5,\"method\":\"meeting.pause\",\"params\":{\"meeting\":\"m1\"}}")
        == .call(id: .int(5), call: .meetingPause(meeting: "m1")))
    #expect(
      try decode("{\"id\":6,\"method\":\"meeting.resume\",\"params\":{\"meeting\":\"m1\"}}")
        == .call(id: .int(6), call: .meetingResume(meeting: "m1")))
    #expect(
      try decode("{\"id\":7,\"method\":\"meeting.end\",\"params\":{\"meeting\":\"m1\"}}")
        == .call(id: .int(7), call: .meetingEnd(meeting: "m1")))
    #expect(
      try decode("{\"id\":8,\"method\":\"meeting.get\",\"params\":{\"meeting\":\"m1\"}}")
        == .call(id: .int(8), call: .meetingGet(meeting: "m1")))
  }

  @Test("decodes meeting.rename's if_rev compare-and-set")
  func meetingRename() throws {
    let json = """
      {"id":8,"method":"meeting.rename","params":{"meeting":"m1","title":"New","if_rev":41}}
      """
    #expect(
      try decode(json)
        == .call(
          id: .int(8),
          call: .meetingRename(MeetingRenameParams(meeting: "m1", title: "New", ifRev: 41))))
  }

  @Test("decodes a meeting.attendee upsert with ISO-8601 join/leave instants")
  func meetingAttendee() throws {
    let json = """
      {"id":9,"method":"meeting.attendee","params":{"meeting":"m1","id":"spaces/x/devices/y",
       "display_name":"Jane Doe","joined":"2026-07-17T10:30:00Z","source":"browser:meet:jane"}}
      """
    let frame = try decode(json)
    #expect(
      frame
        == .call(
          id: .int(9),
          call: .meetingAttendee(
            MeetingAttendeeParams(
              meeting: "m1", id: "spaces/x/devices/y", displayName: "Jane Doe",
              joined: base, source: "browser:meet:jane"))))
  }

  @Test("decodes session.open with v1-compatible param fields")
  func sessionOpen() throws {
    let json = """
      {"id":10,"method":"session.open","params":{"sources":["mic"],"slug":"standup",
       "trigger":"browser-extension"}}
      """
    #expect(
      try decode(json)
        == .call(
          id: .int(10),
          call: .sessionOpen(
            SessionOpenParams(sources: ["mic"], slug: "standup", trigger: .browserExtension))))
  }

  @Test("mark accepts exactly one of last_seconds or start+end")
  func markDualShape() throws {
    let relative = """
      {"id":11,"method":"mark","params":{"sources":["mic"],"slug":"chat","last_seconds":1800}}
      """
    #expect(
      try decode(relative)
        == .call(
          id: .int(11), call: .mark(sources: ["mic"], slug: "chat", range: .lastSeconds(1800)))
    )

    let absolute = """
      {"id":12,"method":"mark","params":{"sources":["mic"],"slug":"chat",
       "start":"2026-07-17T10:30:00Z","end":"2026-07-17T11:00:00Z"}}
      """
    #expect(
      try decode(absolute)
        == .call(
          id: .int(12),
          call: .mark(
            sources: ["mic"], slug: "chat",
            range: .absolute(start: base, end: base.advanced(by: 1800)))))

    let both = """
      {"id":13,"method":"mark","params":{"sources":["mic"],"slug":"chat","last_seconds":60,
       "start":"2026-07-17T10:30:00Z","end":"2026-07-17T11:00:00Z"}}
      """
    #expect(throws: (any Error).self) { try decode(both) }

    let neither = """
      {"id":14,"method":"mark","params":{"sources":["mic"],"slug":"chat"}}
      """
    #expect(throws: (any Error).self) { try decode(neither) }
  }

  @Test("decodes subscribe filters, defaulting omitted lists to empty")
  func subscribeParams() throws {
    let filtered = try decode(
      "{\"id\":1,\"method\":\"subscribe\",\"params\":{\"events\":[\"job\"]}}")
    #expect(
      filtered == .call(id: .int(1), call: .subscribe(SubscribeParams(events: [.job]))))
    let bare = try decode("{\"id\":2,\"method\":\"subscribe\"}")
    #expect(bare == .call(id: .int(2), call: .subscribe(SubscribeParams())))
  }

  @Test("decodes job.publish")
  func jobPublish() throws {
    let json = """
      {"id":12,"method":"job.publish","params":{"job":"j3","kind":"transcribe",
       "meeting":"m1","state":"running"}}
      """
    #expect(
      try decode(json)
        == .call(
          id: .int(12),
          call: .jobPublish(
            JobPublishParams(job: "j3", kind: "transcribe", meeting: "m1", state: .running))))
  }

  @Test("an unknown method fails to decode")
  func unknownMethod() {
    #expect(throws: (any Error).self) {
      try decode("{\"id\":1,\"method\":\"meeting.resolve\",\"params\":{}}")
    }
  }

  @Test("the lenient head decode still recovers id and method from bad params")
  func headDecode() throws {
    let head = try JSONDecoder().decode(
      ControlRequestHead.self,
      from: Data("{\"id\":\"x\",\"method\":\"meeting.pause\",\"params\":42}".utf8))
    #expect(head.id == .string("x"))
    #expect(head.method == "meeting.pause")
  }

  @Test(
    "round-trips representative calls through encode/decode",
    arguments: [
      ControlCall.status,
      .subscribe(SubscribeParams(events: [.vad], sources: ["mic"])),
      .meetingStart(
        MeetingStartParams(platform: "meet", externalID: "abc", trigger: .browserExtension)),
      .meetingPause(meeting: "m1"),
      .meetingAttendee(MeetingAttendeeParams(meeting: "m1", id: "a", displayName: "Jane")),
      .sessionOpen(SessionOpenParams(sources: ["mic"], slug: "standup")),
      .sessionClose(id: "sid"),
      .sessionAddSource(id: "sid", source: "browser:meet:jane"),
      .mark(sources: ["mic"], slug: "chat", range: .lastSeconds(1800)),
      .segmentPublish(
        SegmentPublishParams(session: "sid", speaker: "You", start: 1, end: 2, text: "hi")),
      .jobPublish(JobPublishParams(job: "j1", kind: "transcribe", state: .done)),
      .sourcesRemove(source: "mic"),
      .capturePause(source: nil),
      .captureResume(source: "mic"),
      .flush,
    ])
  func roundTrips(call: ControlCall) throws {
    let frame = ControlRequestFrame.call(id: .int(9), call: call)
    #expect(try roundTrip(frame) == frame)
  }
}

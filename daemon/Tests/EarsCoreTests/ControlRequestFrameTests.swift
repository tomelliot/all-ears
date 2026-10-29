import Foundation
import Testing

@testable import EarsCore

/// Covers the v2 request envelope (`{"id", "method", "params"}`) and its
/// typed param decoding — `docs/specs/control-protocol.md`'s wire
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
    let stringFrame = try roundTrip(.call(id: .string("req-77"), call: .sessionList))
    #expect(stringFrame.id == .string("req-77"))
  }

  @Test(
    "decodes params-less methods",
    arguments: [
      ("status", ControlCall.status),
      ("session.list", ControlCall.sessionList),
      ("sources.list", ControlCall.sourcesList),
      ("flush", ControlCall.flush),
    ])
  func decodesParamsless(method: String, expected: ControlCall) throws {
    let frame = try decode("{\"id\":1,\"method\":\"\(method)\"}")
    #expect(frame == .call(id: .int(1), call: expected))
  }

  @Test("decodes session.start with identity, sources, and trigger")
  func decodesSessionStart() throws {
    let json = """
      {"id":3,"method":"session.start","params":{"platform":"meet","external_id":"abc",
       "title":"Weekly sync","sources":["mic"],"trigger":"browser-extension"}}
      """
    let frame = try decode(json)
    let expected = SessionStartParams(
      platform: "meet", externalID: "abc", title: "Weekly sync", sources: ["mic"],
      trigger: .browserExtension)
    #expect(frame == .call(id: .int(3), call: .sessionStart(expected)))
    #expect(expected.identity == SessionIdentity(platform: "meet", externalID: "abc"))
  }

  @Test("session.start with no identity params is a manual session")
  func manualSessionStart() throws {
    let frame = try decode("{\"id\":4,\"method\":\"session.start\"}")
    guard case .call(_, .sessionStart(let params)) = frame else {
      Issue.record("expected sessionStart")
      return
    }
    #expect(params.identity == nil)
    #expect(params.sources.isEmpty)
  }

  @Test("decodes the session-ref verbs")
  func sessionRefVerbs() throws {
    #expect(
      try decode("{\"id\":5,\"method\":\"session.pause\",\"params\":{\"session\":\"m1\"}}")
        == .call(id: .int(5), call: .sessionPause(session: "m1")))
    #expect(
      try decode("{\"id\":6,\"method\":\"session.resume\",\"params\":{\"session\":\"m1\"}}")
        == .call(id: .int(6), call: .sessionResume(session: "m1")))
    #expect(
      try decode("{\"id\":7,\"method\":\"session.end\",\"params\":{\"session\":\"m1\"}}")
        == .call(id: .int(7), call: .sessionEnd(session: "m1")))
    #expect(
      try decode("{\"id\":8,\"method\":\"session.get\",\"params\":{\"session\":\"m1\"}}")
        == .call(id: .int(8), call: .sessionGet(session: "m1")))
  }

  @Test("decodes session.rename's if_rev compare-and-set")
  func sessionRename() throws {
    let json = """
      {"id":8,"method":"session.rename","params":{"session":"m1","title":"New","if_rev":41}}
      """
    #expect(
      try decode(json)
        == .call(
          id: .int(8),
          call: .sessionRename(SessionRenameParams(session: "m1", title: "New", ifRev: 41))))
  }

  @Test("decodes session.retry with and without an input path")
  func sessionRetry() throws {
    let json = """
      {"id":8,"method":"session.retry","params":{"session":"m1","from":"cleanup","input":"/t.md"}}
      """
    #expect(
      try decode(json)
        == .call(
          id: .int(8),
          call: .sessionRetry(SessionRetryParams(session: "m1", from: "cleanup", input: "/t.md"))))
    let withoutInput = """
      {"id":9,"method":"session.retry","params":{"session":"m1","from":"transcribe"}}
      """
    #expect(
      try decode(withoutInput)
        == .call(
          id: .int(9),
          call: .sessionRetry(SessionRetryParams(session: "m1", from: "transcribe"))))
    #expect(ControlMethod.sessionRetry.capability == .admin)
  }

  @Test("decodes a session.attendee upsert with ISO-8601 join/leave instants")
  func sessionAttendee() throws {
    let json = """
      {"id":9,"method":"session.attendee","params":{"session":"m1","id":"spaces/x/devices/y",
       "display_name":"Jane Doe","joined":"2026-07-17T10:30:00Z","source":"browser:meet:jane"}}
      """
    let frame = try decode(json)
    #expect(
      frame
        == .call(
          id: .int(9),
          call: .sessionAttendee(
            SessionAttendeeParams(
              session: "m1", id: "spaces/x/devices/y", displayName: "Jane Doe",
              joined: base, source: "browser:meet:jane"))))
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
       "session":"m1","state":"running"}}
      """
    #expect(
      try decode(json)
        == .call(
          id: .int(12),
          call: .jobPublish(
            JobPublishParams(job: "j3", kind: "transcribe", session: "m1", state: .running))))
  }

  @Test("an unknown method fails to decode")
  func unknownMethod() {
    #expect(throws: (any Error).self) {
      try decode("{\"id\":1,\"method\":\"session.resolve\",\"params\":{}}")
    }
  }

  @Test("the lenient head decode still recovers id and method from bad params")
  func headDecode() throws {
    let head = try JSONDecoder().decode(
      ControlRequestHead.self,
      from: Data("{\"id\":\"x\",\"method\":\"session.pause\",\"params\":42}".utf8))
    #expect(head.id == .string("x"))
    #expect(head.method == "session.pause")
  }

  @Test(
    "round-trips representative calls through encode/decode",
    arguments: [
      ControlCall.status,
      .subscribe(SubscribeParams(events: [.vad], sources: ["mic"])),
      .sessionStart(
        SessionStartParams(platform: "meet", externalID: "abc", trigger: .browserExtension)),
      .sessionPause(session: "m1"),
      .sessionAttendee(SessionAttendeeParams(session: "m1", id: "a", displayName: "Jane")),
      .segmentPublish(
        SegmentPublishParams(session: "m1", speaker: "You", start: 1, end: 2, text: "hi")),
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

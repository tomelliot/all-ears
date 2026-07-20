import EarsCore
import EarsCoreTestSupport
import EarsIPC
import Foundation
import Synchronization
import Testing

@testable import EarsDaemonKit

/// Covers ``ControlServer``'s v2 dispatch: the reply frames it builds
/// (`{"id", "result"}` / `{"id", "error": {"code", "message"}}`), the stable
/// error-code mapping, the `subscribe` snapshot, and routing into the
/// meeting/session registries. Transport-level concerns (`hello` gating,
/// capability tiers) live in `EarsIPCTests` — every call reaching this actor
/// has already cleared them.
@Suite("ControlServer")
struct ControlServerTests {
  private func makeSessions(
    dataRoot: URL, clock: any NowProviding, known: Set<SourceID> = []
  ) -> SessionRegistry {
    SessionRegistry(dataRoot: dataRoot, knownSourceIDs: { known }, clock: clock)
  }

  private func makeDataRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ControlServerTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func makeServer(
    captureActors: [SourceID: CaptureActor] = [:],
    dataRoot: URL,
    startInstant: Instant = Instant(secondsSinceEpoch: 0),
    clock: any NowProviding,
    bus: EventBus? = nil,
    meetings: MeetingRegistry? = nil,
    known: Set<SourceID> = [],
    onSessionClosed: (@Sendable (SessionDescriptor) async -> Void)? = nil
  ) -> ControlServer {
    ControlServer(
      captureActors: captureActors,
      sessions: makeSessions(dataRoot: dataRoot, clock: clock, known: known),
      dataRoot: dataRoot,
      startInstant: startInstant,
      clock: clock,
      bus: bus,
      meetings: meetings,
      onSessionClosed: onSessionClosed)
  }

  /// Decodes a `ControlReply`'s JSON frame (with a fixed test id) for
  /// assertions.
  private func frame(_ reply: ControlReply) throws -> [String: Any] {
    let data = try reply.encoded(id: .int(1), using: JSONEncoder())
    let object: [String: Any]? = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    return try #require(object)
  }

  /// The reply's `result` object, failing the test on an error frame.
  private func result(_ reply: ControlReply) throws -> [String: Any] {
    let json = try frame(reply)
    #expect(json["error"] == nil, "expected a result frame, got \(json)")
    let value: [String: Any]? = json["result"] as? [String: Any]
    return try #require(value)
  }

  /// The reply's `error.code`, failing the test on a result frame.
  private func errorCode(_ reply: ControlReply) throws -> String {
    let json = try frame(reply)
    let error: [String: Any]? = json["error"] as? [String: Any]
    let code: String? = try #require(error)["code"] as? String
    return try #require(code)
  }

  // MARK: - status / subscribe

  @Test("status reports uptime, sources, and the (empty) meeting/session lists")
  func statusReportsUptime() async throws {
    let clock = ManualClock(Instant(secondsSinceEpoch: 1000))
    let server = makeServer(
      dataRoot: try makeDataRoot(), startInstant: Instant(secondsSinceEpoch: 100), clock: clock)

    let data = try result(await server.handle(.status))
    #expect(data["uptime_s"] as? Int == 900)
    #expect((data["sources"] as? [Any])?.isEmpty == true)
    #expect((data["meetings"] as? [Any])?.isEmpty == true)
    #expect((data["sessions"] as? [Any])?.isEmpty == true)
  }

  @Test("status never reports negative uptime, even if the clock precedes startInstant")
  func statusClampsNegativeUptime() async throws {
    let clock = ManualClock(Instant(secondsSinceEpoch: 50))
    let server = makeServer(
      dataRoot: try makeDataRoot(), startInstant: Instant(secondsSinceEpoch: 100), clock: clock)

    let data = try result(await server.handle(.status))
    #expect(data["uptime_s"] as? Int == 0)
  }

  @Test("subscribe returns a snapshot tagged with the bus's current revision")
  func subscribeSnapshot() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock()
    let bus = EventBus()
    await bus.publish(.source(id: "mic", state: .capturing))  // rev 1
    let meetings = MeetingRegistry(dataRoot: dataRoot, clock: clock, bus: bus)
    let started = try await meetings.start(MeetingStartParams(title: "standup"))  // rev 2
    let server = makeServer(dataRoot: dataRoot, clock: clock, bus: bus, meetings: meetings)

    let data = try result(await server.handle(.subscribe(SubscribeParams())))
    #expect(data["rev"] as? Int == 2)
    let snapshotMeetings: [[String: Any]]? = data["meetings"] as? [[String: Any]]
    #expect(try #require(snapshotMeetings).count == 1)
    #expect(try #require(snapshotMeetings).first?["id"] as? String == started.id)
  }

  // MARK: - sources / capture error mapping

  @Test("sources.add fails clearly rather than silently accepting")
  func sourcesAddNotSupported() async throws {
    let server = makeServer(dataRoot: try makeDataRoot(), clock: ManualClock())
    let spec = SourceSpec(id: "app:us.zoom.xos", sourceClass: .app)
    #expect(try errorCode(await server.handle(.sourcesAdd(spec))) == "invalid_request")
  }

  @Test(
    "source verbs on an unknown id fail with source_not_found",
    arguments: [
      ControlCall.sourcesEnable(source: "mic"),
      .sourcesDisable(source: "mic"),
      .sourcesRemove(source: "mic"),
      .capturePause(source: "mic"),
      .captureResume(source: "mic"),
    ])
  func unknownSourceMapping(call: ControlCall) async throws {
    let server = makeServer(dataRoot: try makeDataRoot(), clock: ManualClock())
    let reply = await server.handle(call)
    #expect(try errorCode(reply) == "source_not_found")
    let json = try frame(reply)
    let error: [String: Any]? = json["error"] as? [String: Any]
    #expect((try #require(error)["message"] as? String)?.contains("mic") == true)
  }

  @Test(
    "fan-out verbs over zero sources succeed trivially",
    arguments: [ControlCall.capturePause(source: nil), .captureResume(source: nil), .flush])
  func fanOutEmpty(call: ControlCall) async throws {
    let server = makeServer(dataRoot: try makeDataRoot(), clock: ManualClock())
    _ = try result(await server.handle(call))
  }

  // MARK: - notification-only publishes

  @Test("segment.publish and job.publish forward to the bus and reply ok")
  func publishesForwardToBus() async throws {
    let clock = ManualClock()
    let bus = EventBus()
    let recorded = Mutex<[EventFrame]>([])
    await bus.attach { frame in recorded.withLock { $0.append(frame) } }
    let server = makeServer(dataRoot: try makeDataRoot(), clock: clock, bus: bus)

    let segment = SegmentPublishParams(
      session: "s1", speaker: "You", start: 604.1, end: 611.9, text: "ship it")
    _ = try result(await server.handle(.segmentPublish(segment)))
    let job = JobPublishParams(job: "j1", kind: "transcribe", meeting: "m1", state: .running)
    _ = try result(await server.handle(.jobPublish(job)))

    for _ in 0..<1_000 {
      if recorded.withLock({ $0.count }) >= 2 { break }
      await Task.yield()
    }
    let frames = recorded.withLock { $0 }
    #expect(frames.map(\.event) == [.segment(segment), .job(job)])
    #expect(frames.allSatisfy { $0.rev == nil })  // telemetry, never revved
  }

  @Test("segment.publish with no bus attached still replies ok (drop, don't fail)")
  func segmentPublishWithoutBusSucceeds() async throws {
    let server = makeServer(dataRoot: try makeDataRoot(), clock: ManualClock())
    _ = try result(
      await server.handle(
        .segmentPublish(
          SegmentPublishParams(session: "s1", speaker: "You", start: 0, end: 1, text: "hi"))))
  }

  // MARK: - makeHandler wiring

  @Test("makeHandler forwards to handle(_:)")
  func makeHandlerForwards() async throws {
    let server = makeServer(dataRoot: try makeDataRoot(), clock: ManualClock())
    let handler = server.makeHandler()
    let data = try result(await handler(.sourcesList))
    #expect((data["sources"] as? [Any])?.isEmpty == true)
  }

  // MARK: - meeting dispatch

  @Test("meeting verbs fail with internal when no registry is wired")
  func meetingWithoutRegistryFails() async throws {
    let server = makeServer(dataRoot: try makeDataRoot(), clock: ManualClock())
    #expect(
      try errorCode(await server.handle(.meetingStart(MeetingStartParams()))) == "internal")
  }

  @Test("meeting.start is idempotent through the wire and returns the full meeting object")
  func meetingStartIdempotent() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock()
    let meetings = MeetingRegistry(dataRoot: dataRoot, clock: clock)
    let server = makeServer(dataRoot: dataRoot, clock: clock, meetings: meetings)
    let params = MeetingStartParams(
      platform: "meet", externalID: "abc", trigger: .browserExtension)

    let first = try result(await server.handle(.meetingStart(params)))
    let firstID = try #require(first["id"] as? String)
    #expect(first["state"] as? String == "active")
    #expect((first["intervals"] as? [Any])?.count == 1)

    let again = try result(await server.handle(.meetingStart(params)))
    #expect(again["id"] as? String == firstID)
  }

  @Test("meeting error mapping: not-found, ended, and rename conflict codes")
  func meetingErrorMapping() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock()
    let meetings = MeetingRegistry(dataRoot: dataRoot, clock: clock)
    let server = makeServer(dataRoot: dataRoot, clock: clock, meetings: meetings)

    #expect(
      try errorCode(await server.handle(.meetingPause(meeting: "nope"))) == "meeting_not_found")

    let started = try result(
      await server.handle(.meetingStart(MeetingStartParams(title: "standup"))))
    let id = try #require(started["id"] as? String)
    _ = try result(await server.handle(.meetingEnd(meeting: id)))
    #expect(try errorCode(await server.handle(.meetingResume(meeting: id))) == "meeting_ended")
    #expect(
      try errorCode(
        await server.handle(
          .meetingRename(MeetingRenameParams(meeting: "nope", title: "x", ifRev: nil))))
        == "meeting_not_found")

    let second = try result(
      await server.handle(.meetingStart(MeetingStartParams(title: "retro"))))
    let secondID = try #require(second["id"] as? String)
    #expect(
      try errorCode(
        await server.handle(
          .meetingRename(MeetingRenameParams(meeting: secondID, title: "x", ifRev: 999))))
        == "conflict")
  }

  @Test("meeting.list returns live + recent meetings")
  func meetingList() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock()
    let meetings = MeetingRegistry(dataRoot: dataRoot, clock: clock)
    let server = makeServer(dataRoot: dataRoot, clock: clock, meetings: meetings)
    _ = try result(await server.handle(.meetingStart(MeetingStartParams(title: "standup"))))

    let data = try result(await server.handle(.meetingList))
    #expect((data["meetings"] as? [Any])?.count == 1)
  }

  // MARK: - session dispatch

  @Test("session errors map to the stable codes")
  func sessionErrorMapping() async throws {
    let server = makeServer(dataRoot: try makeDataRoot(), clock: ManualClock(), known: ["mic"])

    #expect(
      try errorCode(await server.handle(.sessionClose(id: "nope"))) == "session_not_found")
    #expect(
      try errorCode(
        await server.handle(
          .sessionOpen(SessionOpenParams(sources: ["bogus"], slug: "x"))))
        == "source_not_found")
    #expect(
      try errorCode(
        await server.handle(.sessionOpen(SessionOpenParams(sources: [], slug: "x"))))
        == "invalid_request")
  }

  @Test("session.open records the wire trigger, and close fires onSessionClosed with it")
  func sessionOpenTriggerAndOnClosed() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: 1_784_284_200))
    let closed = Mutex<[SessionDescriptor]>([])
    let server = makeServer(
      dataRoot: dataRoot, clock: clock, known: ["mic"],
      onSessionClosed: { descriptor in
        closed.withLock { $0.append(descriptor) }
      })

    let opened = try result(
      await server.handle(
        .sessionOpen(
          SessionOpenParams(sources: ["mic"], slug: "call", trigger: .browserExtension))))
    let id = try #require(opened["id"] as? String)

    _ = try result(await server.handle(.sessionAddSource(id: id, source: "mic")))
    _ = try result(await server.handle(.sessionClose(id: id)))

    let descriptors = closed.withLock { $0 }
    #expect(descriptors.count == 1)
    #expect(descriptors.first?.trigger == .browserExtension)
  }
}

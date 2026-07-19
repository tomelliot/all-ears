import EarsCore
import EarsCoreTestSupport
import EarsIPC
import Foundation
import Synchronization
import Testing

@testable import EarsDaemonKit

/// Coverage scope (see the task report for the full rationale): at the time
/// this file was written, ``CaptureActor``'s and ``SessionRegistry``'s method
/// *bodies* are still `fatalError` stubs -- two other in-flight tasks fill
/// them in. Every method on both types crashes unconditionally when called,
/// regardless of arguments or receiver state, so any dispatch path that would
/// actually invoke one can't be exercised yet.
///
/// This suite therefore covers exactly the paths ``ControlServer/handle(_:)``
/// can run **without** calling into either collaborator's stubbed bodies:
///
/// - `sources.add` / `ingest.open`: fixed "not supported" replies that never
///   touch either collaborator.
/// - Unknown-source-id error mapping for `sources.enable`/`disable`/`remove`
///   and single-source `capture.pause`/`resume`: the `captureActors[id]`
///   lookup fails before any actor method would be called.
/// - `status` / `sources.list` / fan-out `capture.pause`/`resume` / `flush`
///   with an **empty** `captureActors` map: the aggregation/fan-out loops
///   correctly do nothing when there's nothing to iterate, without calling
///   `CaptureActor.status()`/`.pause()`/etc.
///
/// `session.open`/`session.close`/`session.list`/`mark` call straight into
/// `SessionRegistry` with no prior validation in `ControlServer` itself, so
/// there is no reachable path through them that doesn't hit a `fatalError` --
/// not even the error-mapping paths. Full dispatch coverage for those, and
/// for the success/error paths through a real `CaptureActor`, is deferred to
/// the Wave 4 integration step once all three pieces are merged.
@Suite("ControlServer")
struct ControlServerTests {
  private func makeSessions(dataRoot: URL, clock: any NowProviding) -> SessionRegistry {
    SessionRegistry(dataRoot: dataRoot, knownSourceIDs: { [] }, clock: clock)
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
    clock: any NowProviding
  ) -> ControlServer {
    ControlServer(
      captureActors: captureActors,
      sessions: makeSessions(dataRoot: dataRoot, clock: clock),
      dataRoot: dataRoot,
      startInstant: startInstant,
      clock: clock)
  }

  /// Decodes a `ControlReply`'s JSON envelope for assertions, mirroring
  /// `EarsIPCTests.ControlReplyTests`'s helper.
  private func envelope(_ reply: ControlReply) throws -> [String: Any] {
    let data = try reply.encoded(using: JSONEncoder())
    let object: [String: Any]? = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    return try #require(object)
  }

  /// `json[key]` as a `[String: Any]`, or fails the test with a clear message.
  ///
  /// Deliberately splits the `as?` cast onto its own statement rather than
  /// writing `try #require(json[key] as? [String: Any])` inline: the compiler
  /// mis-diagnoses that inline form as "no calls to throwing functions occur
  /// within 'try' expression" (a false positive -- the cast can fail and
  /// `#require` does throw), which the strict zero-warnings build rejects.
  private func requireDict(_ json: [String: Any], key: String) throws -> [String: Any] {
    let value: [String: Any]? = json[key] as? [String: Any]
    return try #require(value)
  }

  /// `json[key]` as a `String`, or fails the test. See ``requireDict(_:key:)``
  /// for why the cast is split onto its own statement.
  private func requireString(_ json: [String: Any], key: String) throws -> String {
    let value: String? = json[key] as? String
    return try #require(value)
  }

  // MARK: - status / sources.list

  @Test("status reports uptime derived from the clock and startInstant, with no sources")
  func statusReportsUptime() async throws {
    let clock = ManualClock(Instant(secondsSinceEpoch: 1000))
    let server = makeServer(
      dataRoot: try makeDataRoot(), startInstant: Instant(secondsSinceEpoch: 100), clock: clock)

    let reply = await server.handle(.status)
    let json = try envelope(reply)
    #expect(json["ok"] as? Bool == true)
    let data = try requireDict(json, key: "data")
    #expect(data["uptime_s"] as? Int == 900)
    #expect((data["sources"] as? [Any])?.isEmpty == true)
  }

  @Test("status never reports negative uptime, even if the clock precedes startInstant")
  func statusClampsNegativeUptime() async throws {
    let clock = ManualClock(Instant(secondsSinceEpoch: 50))
    let server = makeServer(
      dataRoot: try makeDataRoot(), startInstant: Instant(secondsSinceEpoch: 100), clock: clock)

    let reply = await server.handle(.status)
    let json = try envelope(reply)
    let data = try requireDict(json, key: "data")
    #expect(data["uptime_s"] as? Int == 0)
  }

  @Test("sources.list returns an empty list when there are no sources")
  func sourcesListEmpty() async throws {
    let clock = ManualClock()
    let server = makeServer(dataRoot: try makeDataRoot(), clock: clock)

    let reply = await server.handle(.sourcesList)
    let json = try envelope(reply)
    #expect(json["ok"] as? Bool == true)
    let data = try requireDict(json, key: "data")
    #expect((data["sources"] as? [Any])?.isEmpty == true)
  }

  // MARK: - sources.add (not supported)

  @Test("sources.add fails clearly rather than silently accepting")
  func sourcesAddNotSupported() async throws {
    let clock = ManualClock()
    let server = makeServer(dataRoot: try makeDataRoot(), clock: clock)

    let spec = SourceSpec(id: "app:us.zoom.xos", sourceClass: .app)
    let reply = await server.handle(.sourcesAdd(spec))
    let json = try envelope(reply)
    #expect(json["ok"] as? Bool == false)
    let message = try requireString(json, key: "error")
    #expect(message.contains("sources.add"))
    #expect(message.contains("not supported"))
  }

  // MARK: - ingest.open (not supported)

  @Test("ingest.open fails clearly on the control socket — it's WebSocket-only")
  func ingestOpenNotSupported() async throws {
    let clock = ManualClock()
    let server = makeServer(dataRoot: try makeDataRoot(), clock: clock)

    let format = AudioFormatSpec(sampleRate: 48000, channels: 1, encoding: "pcm_s16le")
    let reply = await server.handle(.ingestOpen(source: "browser:meet", format: format))
    let json = try envelope(reply)
    #expect(json["ok"] as? Bool == false)
    let message = try requireString(json, key: "error")
    #expect(message.contains("ingest.open"))
    #expect(message.contains("WebSocket"))
  }

  @Test("ingest.close fails clearly on the control socket — it's WebSocket-only")
  func ingestCloseNotSupported() async throws {
    let clock = ManualClock()
    let server = makeServer(dataRoot: try makeDataRoot(), clock: clock)

    let reply = await server.handle(.ingestClose(streamID: "s1"))
    let json = try envelope(reply)
    #expect(json["ok"] as? Bool == false)
    let message = try requireString(json, key: "error")
    #expect(message.contains("ingest.close"))
    #expect(message.contains("WebSocket"))
  }

  // MARK: - unknown source id mapping

  @Test("sources.enable on an unknown source fails with a message naming the id")
  func sourcesEnableUnknownSource() async throws {
    let clock = ManualClock()
    let server = makeServer(dataRoot: try makeDataRoot(), clock: clock)

    let reply = await server.handle(.sourcesEnable(source: "mic"))
    let json = try envelope(reply)
    #expect(json["ok"] as? Bool == false)
    let message = try requireString(json, key: "error")
    #expect(message.contains("mic"))
  }

  @Test("sources.disable on an unknown source fails with a message naming the id")
  func sourcesDisableUnknownSource() async throws {
    let clock = ManualClock()
    let server = makeServer(dataRoot: try makeDataRoot(), clock: clock)

    let reply = await server.handle(.sourcesDisable(source: "mic"))
    let json = try envelope(reply)
    #expect(json["ok"] as? Bool == false)
    let message = try requireString(json, key: "error")
    #expect(message.contains("mic"))
  }

  @Test("sources.remove on an unknown source fails with a message naming the id")
  func sourcesRemoveUnknownSource() async throws {
    let clock = ManualClock()
    let server = makeServer(dataRoot: try makeDataRoot(), clock: clock)

    let reply = await server.handle(.sourcesRemove(source: "mic"))
    let json = try envelope(reply)
    #expect(json["ok"] as? Bool == false)
    let message = try requireString(json, key: "error")
    #expect(message.contains("mic"))
  }

  @Test("capture.pause on an unknown concrete source fails with a message naming the id")
  func capturePauseUnknownSource() async throws {
    let clock = ManualClock()
    let server = makeServer(dataRoot: try makeDataRoot(), clock: clock)

    let reply = await server.handle(.capturePause(source: "mic"))
    let json = try envelope(reply)
    #expect(json["ok"] as? Bool == false)
    let message = try requireString(json, key: "error")
    #expect(message.contains("mic"))
  }

  @Test("capture.resume on an unknown concrete source fails with a message naming the id")
  func captureResumeUnknownSource() async throws {
    let clock = ManualClock()
    let server = makeServer(dataRoot: try makeDataRoot(), clock: clock)

    let reply = await server.handle(.captureResume(source: "mic"))
    let json = try envelope(reply)
    #expect(json["ok"] as? Bool == false)
    let message = try requireString(json, key: "error")
    #expect(message.contains("mic"))
  }

  // MARK: - fan-out with no sources (capture.pause/resume with source == nil, flush)

  @Test("capture.pause with no source fans out to (zero) sources and succeeds trivially")
  func capturePauseFanOutEmpty() async throws {
    let clock = ManualClock()
    let server = makeServer(dataRoot: try makeDataRoot(), clock: clock)

    let reply = await server.handle(.capturePause(source: nil))
    let json = try envelope(reply)
    #expect(json["ok"] as? Bool == true)
  }

  @Test("capture.resume with no source fans out to (zero) sources and succeeds trivially")
  func captureResumeFanOutEmpty() async throws {
    let clock = ManualClock()
    let server = makeServer(dataRoot: try makeDataRoot(), clock: clock)

    let reply = await server.handle(.captureResume(source: nil))
    let json = try envelope(reply)
    #expect(json["ok"] as? Bool == true)
  }

  @Test("flush fans out to (zero) sources and succeeds trivially")
  func flushFanOutEmpty() async throws {
    let clock = ManualClock()
    let server = makeServer(dataRoot: try makeDataRoot(), clock: clock)

    let reply = await server.handle(.flush)
    let json = try envelope(reply)
    #expect(json["ok"] as? Bool == true)
  }

  // MARK: - segment.publish

  @Test("segment.publish forwards the event to the injected sink and replies ok")
  func segmentPublishForwardsToSink() async throws {
    let clock = ManualClock()
    let published = Mutex<[EarsEvent]>([])
    let server = ControlServer(
      captureActors: [:],
      sessions: makeSessions(dataRoot: try makeDataRoot(), clock: clock),
      dataRoot: try makeDataRoot(),
      startInstant: Instant(secondsSinceEpoch: 0),
      clock: clock,
      eventSink: { event in published.withLock { $0.append(event) } })

    let reply = await server.handle(
      .segmentPublish(session: "s1", speaker: "You", start: 604.1, end: 611.9, text: "ship it"))
    let json = try envelope(reply)
    #expect(json["ok"] as? Bool == true)
    #expect(
      published.withLock { $0 }
        == [.segment(session: "s1", speaker: "You", start: 604.1, end: 611.9, text: "ship it")])
  }

  @Test("segment.publish with no sink attached still replies ok (drop, don't fail)")
  func segmentPublishWithoutSinkSucceeds() async throws {
    let clock = ManualClock()
    let server = makeServer(dataRoot: try makeDataRoot(), clock: clock)

    let reply = await server.handle(
      .segmentPublish(session: "s1", speaker: "You", start: 0, end: 1, text: "hi"))
    let json = try envelope(reply)
    #expect(json["ok"] as? Bool == true)
  }

  // MARK: - makeHandler wiring

  @Test("makeHandler forwards to handle(_:)")
  func makeHandlerForwards() async throws {
    let clock = ManualClock()
    let server = makeServer(dataRoot: try makeDataRoot(), clock: clock)
    let handler = server.makeHandler()

    let reply = await handler(.sourcesList)
    let json = try envelope(reply)
    #expect(json["ok"] as? Bool == true)
  }

  // MARK: - meeting.resolve / session.add_source / trigger provenance

  @Test("meeting.resolve fails clearly when no meeting registry is wired")
  func meetingResolveWithoutRegistryFails() async throws {
    let server = makeServer(dataRoot: try makeDataRoot(), clock: ManualClock())

    let reply = await server.handle(.meetingResolve(platform: "meet", externalID: "abc"))
    let json = try envelope(reply)
    #expect(json["ok"] as? Bool == false)
  }

  @Test("meeting.resolve returns a stable meeting_id via the registry")
  func meetingResolveReturnsStableID() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock()
    let server = ControlServer(
      captureActors: [:],
      sessions: makeSessions(dataRoot: dataRoot, clock: clock),
      dataRoot: dataRoot,
      startInstant: Instant(secondsSinceEpoch: 0),
      clock: clock,
      meetings: MeetingRegistry(dataRoot: dataRoot, clock: clock))

    let first = try envelope(
      await server.handle(.meetingResolve(platform: "meet", externalID: "AbC")))
    #expect(first["ok"] as? Bool == true)
    let firstID = try requireString(try requireDict(first, key: "data"), key: "meeting_id")
    #expect(!firstID.isEmpty)

    let again = try envelope(
      await server.handle(.meetingResolve(platform: "meet", externalID: "AbC")))
    let againID = try requireString(try requireDict(again, key: "data"), key: "meeting_id")
    #expect(againID == firstID)
  }

  @Test("session.open records the wire trigger, and close fires onSessionClosed with it")
  func sessionOpenTriggerAndOnClosed() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: 1_784_284_200))
    let closed = Mutex<[SessionDescriptor]>([])
    let server = ControlServer(
      captureActors: [:],
      sessions: SessionRegistry(dataRoot: dataRoot, knownSourceIDs: { ["mic"] }, clock: clock),
      dataRoot: dataRoot,
      startInstant: Instant(secondsSinceEpoch: 0),
      clock: clock,
      onSessionClosed: { descriptor in
        closed.withLock { $0.append(descriptor) }
      })

    let openReply = try envelope(
      await server.handle(
        .sessionOpen(
          sources: ["mic"], slug: "call", start: nil, vocab: nil, trigger: .browserExtension)))
    #expect(openReply["ok"] as? Bool == true)
    let id = try requireString(try requireDict(openReply, key: "data"), key: "id")

    let addReply = try envelope(await server.handle(.sessionAddSource(id: id, source: "mic")))
    #expect(addReply["ok"] as? Bool == true)

    let closeReply = try envelope(await server.handle(.sessionClose(id: id)))
    #expect(closeReply["ok"] as? Bool == true)
    let descriptors = closed.withLock { $0 }
    #expect(descriptors.count == 1)
    #expect(descriptors.first?.trigger == .browserExtension)
  }
}

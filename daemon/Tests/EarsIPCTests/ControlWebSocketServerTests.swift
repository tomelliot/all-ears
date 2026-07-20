import EarsCore
import Foundation
import Testing

@testable import EarsIPC

/// Protocol-level tests for `ControlWebSocketServer`, modeled directly on
/// `IngestWebSocketServerTests` (same `TestWebSocketClient` byte-level driver
/// over a `FakeSocketConnection`): Origin allowlist, the v2 hello handshake,
/// this transport's restricted capability tier (`observe` + `meetings`),
/// dispatch through the injected handler, subscribe → live event delivery,
/// and the bounded-queue backpressure shared with `ControlSocketServer` via
/// `ControlConnectionTable`.
@Suite("ControlWebSocketServer (v2)")
struct ControlWebSocketServerTests {
  private static let identity = ControlServerIdentity(daemon: "earsd test", bootID: "boot-ws")

  private func wait(for condition: @Sendable () async -> Bool) async {
    while await condition() == false { await Task.yield() }
  }

  /// Records every dispatched call, replying with a canned success.
  private actor RecordingHandler {
    private(set) var calls: [ControlCall] = []

    func handle(_ call: ControlCall) -> ControlReply {
      calls.append(call)
      switch call {
      case .subscribe:
        return ControlReply(
          result: SnapshotData(rev: 41, meetings: [], sources: [], sessions: []))
      case .meetingStart:
        return ControlReply(
          result: Meeting(
            id: "11111111-2222-3333-4444-555555555555",
            identity: MeetingIdentity(platform: "meet", externalID: "AbC"),
            title: "meet AbC",
            state: .active,
            started: Instant(secondsSinceEpoch: 1),
            intervals: [MeetingInterval(start: Instant(secondsSinceEpoch: 1))],
            trigger: .browserExtension,
            rev: 1))
      default:
        return ControlReply(result: EmptyData())
      }
    }
  }

  private func makeServer(
    allowedOrigins: [String],
    outboundQueueBound: Int = ControlWebSocketServer.defaultOutboundQueueBound,
    handler: RecordingHandler
  ) -> (ControlWebSocketServer, FakeSocketListener) {
    let listener = FakeSocketListener()
    let server = ControlWebSocketServer(
      listener: listener,
      allowedOrigins: allowedOrigins,
      identity: Self.identity,
      outboundQueueBound: outboundQueueBound,
      handler: { call in await handler.handle(call) })
    return (server, listener)
  }

  private func upgrade(
    _ connection: FakeSocketConnection, origin: String = "chrome-extension://abc"
  ) async -> String? {
    connection.feed(TestWebSocketClient.upgradeRequest(path: "/control", origin: origin))
    guard let response = await firstChunk(connection) else { return nil }
    return statusLine(response)
  }

  /// Sends the hello frame and consumes its reply, returning the decoded
  /// result.
  private func hello(_ connection: FakeSocketConnection) async throws -> HelloResult? {
    connection.feed(
      TestWebSocketClient.text(
        #"{"id":0,"method":"hello","params":{"protocol":2,"client":"test/0"}}"#))
    guard let bytes = await firstChunk(connection), let frame = decodeServerFrame(bytes) else {
      return nil
    }
    return try JSONDecoder().decode(
      ControlResponseFrame<HelloResult>.self, from: Data(frame.payload)
    ).get()
  }

  @Test("hello advertises the restricted observe+meetings capability tier")
  func helloCapabilityTier() async throws {
    let handler = RecordingHandler()
    let (server, listener) = makeServer(
      allowedOrigins: ["chrome-extension://abc"], handler: handler)
    let runner = Task { await server.run() }
    let connection = FakeSocketConnection()
    listener.accept(connection)
    _ = await upgrade(connection)

    let result = try await hello(connection)
    #expect(result?.bootID == "boot-ws")
    #expect(result.map { Set($0.capabilities) } == Capability.controlWebSocket)

    await server.shutdown()
    _ = await runner.value
  }

  @Test("full round trip: meeting.start dispatches to the handler and replies over WS")
  func fullRoundTrip() async throws {
    let handler = RecordingHandler()
    let (server, listener) = makeServer(
      allowedOrigins: ["chrome-extension://abc"], handler: handler)
    let runner = Task { await server.run() }
    let connection = FakeSocketConnection()
    listener.accept(connection)
    _ = await upgrade(connection)
    _ = try await hello(connection)

    connection.feed(
      TestWebSocketClient.text(
        #"{"id":3,"method":"meeting.start","params":{"platform":"meet","external_id":"AbC","trigger":"browser-extension"}}"#
      ))
    guard let replyBytes = await firstChunk(connection),
      let frame = decodeServerFrame(replyBytes)
    else {
      Issue.record("no meeting.start reply")
      return
    }
    let reply = try JSONDecoder().decode(
      ControlResponseFrame<Meeting>.self, from: Data(frame.payload))
    #expect(reply.id == .int(3))
    #expect(try reply.get().id == "11111111-2222-3333-4444-555555555555")
    #expect(
      await handler.calls == [
        .meetingStart(
          MeetingStartParams(platform: "meet", externalID: "AbC", trigger: .browserExtension))
      ])

    await server.shutdown()
    _ = await runner.value
  }

  @Test("session and admin verbs are not permitted on this transport")
  func capabilityEnforcement() async throws {
    let handler = RecordingHandler()
    let (server, listener) = makeServer(
      allowedOrigins: ["chrome-extension://abc"], handler: handler)
    let runner = Task { await server.run() }
    let connection = FakeSocketConnection()
    listener.accept(connection)
    _ = await upgrade(connection)
    _ = try await hello(connection)

    connection.feed(
      TestWebSocketClient.text(
        #"{"id":4,"method":"session.open","params":{"sources":["mic"],"slug":"x"}}"#))
    guard let bytes = await firstChunk(connection), let frame = decodeServerFrame(bytes) else {
      Issue.record("no reply")
      return
    }
    let reply = try JSONDecoder().decode(
      ControlResponseFrame<EmptyData>.self, from: Data(frame.payload))
    guard case .error(_, let error) = reply else {
      Issue.record("expected not_permitted")
      return
    }
    #expect(error.code == .notPermitted)
    #expect(await handler.calls.isEmpty)  // never reached the handler

    await server.shutdown()
    _ = await runner.value
  }

  @Test("requests before hello are refused with hello_required")
  func helloRequired() async throws {
    let handler = RecordingHandler()
    let (server, listener) = makeServer(
      allowedOrigins: ["chrome-extension://abc"], handler: handler)
    let runner = Task { await server.run() }
    let connection = FakeSocketConnection()
    listener.accept(connection)
    _ = await upgrade(connection)

    connection.feed(TestWebSocketClient.text(#"{"id":1,"method":"status"}"#))
    guard let bytes = await firstChunk(connection), let frame = decodeServerFrame(bytes) else {
      Issue.record("no reply")
      return
    }
    let reply = try JSONDecoder().decode(
      ControlResponseFrame<EmptyData>.self, from: Data(frame.payload))
    guard case .error(_, let error) = reply else {
      Issue.record("expected hello_required")
      return
    }
    #expect(error.code == .helloRequired)

    await server.shutdown()
    _ = await runner.value
  }

  @Test("an empty allowlist fails closed — rejects even a present Origin")
  func emptyAllowlistRejectsAll() async throws {
    let handler = RecordingHandler()
    let (server, listener) = makeServer(allowedOrigins: [], handler: handler)
    let runner = Task { await server.run() }
    let connection = FakeSocketConnection()
    listener.accept(connection)

    let status = await upgrade(connection)
    #expect(status?.contains("403") == true)
    #expect(await server.connectionCount == 0)

    await server.shutdown()
    _ = await runner.value
  }

  @Test("a disallowed origin gets 403; the ingest path gets 404 here")
  func originAndPathRejections() async throws {
    let handler = RecordingHandler()
    let (server, listener) = makeServer(
      allowedOrigins: ["chrome-extension://abc"], handler: handler)
    let runner = Task { await server.run() }

    let evil = FakeSocketConnection()
    listener.accept(evil)
    let evilStatus = await upgrade(evil, origin: "chrome-extension://evil")
    #expect(evilStatus?.contains("403") == true)

    let wrongPath = FakeSocketConnection()
    listener.accept(wrongPath)
    wrongPath.feed(
      TestWebSocketClient.upgradeRequest(path: "/ingest", origin: "chrome-extension://abc"))
    guard let response = await firstChunk(wrongPath), let line = statusLine(response) else {
      Issue.record("no response")
      return
    }
    #expect(line.contains("404"))

    await server.shutdown()
    _ = await runner.value
  }

  @Test("subscribe returns the snapshot and delivers events; state events bypass the filter")
  func subscribeDeliversEvents() async throws {
    let handler = RecordingHandler()
    let (server, listener) = makeServer(
      allowedOrigins: ["chrome-extension://abc"], handler: handler)
    let runner = Task { await server.run() }
    let connection = FakeSocketConnection()
    listener.accept(connection)
    _ = await upgrade(connection)
    _ = try await hello(connection)

    connection.feed(
      TestWebSocketClient.text(#"{"id":2,"method":"subscribe","params":{"events":["job"]}}"#))
    guard let snapshotBytes = await firstChunk(connection),
      let snapshotFrame = decodeServerFrame(snapshotBytes)
    else {
      Issue.record("no snapshot reply")
      return
    }
    let snapshot = try JSONDecoder().decode(
      ControlResponseFrame<SnapshotData>.self, from: Data(snapshotFrame.payload))
    #expect(try snapshot.get().rev == 41)
    #expect(await server.subscriberCount == 1)

    // Filtered-out telemetry is not delivered; a state event always is.
    await server.publish(
      EventFrame(event: .vad(source: "mic", state: .speech, t: Instant(secondsSinceEpoch: 0))))
    await server.publish(EventFrame(event: .source(id: "mic", state: .paused), rev: 42))

    guard let eventBytes = await firstChunk(connection),
      let frame = decodeServerFrame(eventBytes)
    else {
      Issue.record("no event frame")
      return
    }
    let event = try JSONDecoder().decode(EventFrame.self, from: Data(frame.payload))
    #expect(event == EventFrame(event: .source(id: "mic", state: .paused), rev: 42))

    await server.shutdown()
    _ = await runner.value
  }

  @Test("a stalled subscriber's queue drops oldest-first and counts the drops")
  func backpressureDropsAndCounts() async throws {
    let handler = RecordingHandler()
    let (server, listener) = makeServer(
      allowedOrigins: ["chrome-extension://abc"], outboundQueueBound: 2, handler: handler)
    let runner = Task { await server.run() }
    let connection = FakeSocketConnection()
    listener.accept(connection)
    _ = await upgrade(connection)
    _ = try await hello(connection)

    connection.feed(TestWebSocketClient.text(#"{"id":2,"method":"subscribe"}"#))
    await wait { await server.subscriberCount == 1 }
    await connection.stall()

    for i in 0..<10 {
      await server.publish(
        EventFrame(event: .source(id: SourceID("s\(i)"), state: .paused), rev: i))
    }
    #expect(await server.droppedLineCount > 0)

    await connection.unstall()
    await server.shutdown()
    _ = await runner.value
  }

  private func firstChunk(_ connection: FakeSocketConnection) async -> [UInt8]? {
    for await chunk in connection.outbound { return chunk }
    return nil
  }
}

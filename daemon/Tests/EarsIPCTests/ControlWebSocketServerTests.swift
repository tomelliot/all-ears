import EarsCore
import Foundation
import Testing

@testable import EarsIPC

/// Protocol-level tests for `ControlWebSocketServer`, modeled directly on
/// `IngestWebSocketServerTests` (same `TestWebSocketClient` byte-level driver
/// over a `FakeSocketConnection`): Origin allowlist, full-command dispatch
/// through the injected handler, `subscribe` → live event delivery, and the
/// bounded-queue backpressure shared with `ControlSocketServer` via
/// `ControlConnectionTable`.
@Suite("ControlWebSocketServer")
struct ControlWebSocketServerTests {
  private func wait(for condition: @Sendable () async -> Bool) async {
    while await condition() == false { await Task.yield() }
  }

  /// Records every decoded request the server dispatched, replying with a
  /// canned success — the control-plane analogue of ingest's RecordingIngestSink.
  private actor RecordingHandler {
    private(set) var requests: [ControlRequest] = []

    func handle(_ request: ControlRequest) -> ControlReply {
      requests.append(request)
      switch request {
      case .sessionOpen:
        return ControlReply(
          ControlResponse<SessionOpenData>.success(
            SessionOpenData(id: "2026-07-17T10-30-00Z_call")))
      case .meetingResolve:
        return ControlReply(
          ControlResponse<MeetingResolveData>.success(
            MeetingResolveData(meetingID: "11111111-2222-3333-4444-555555555555")))
      default:
        return ControlReply(ControlResponse<EmptyData>.success(EmptyData()))
      }
    }
  }

  private func makeServer(
    allowedOrigins: [String], outboundQueueBound: Int = ControlWebSocketServer
      .defaultOutboundQueueBound,
    handler: RecordingHandler
  ) -> (ControlWebSocketServer, FakeSocketListener) {
    let listener = FakeSocketListener()
    let server = ControlWebSocketServer(
      listener: listener,
      allowedOrigins: allowedOrigins,
      outboundQueueBound: outboundQueueBound,
      handler: { request in await handler.handle(request) })
    return (server, listener)
  }

  private func upgrade(
    _ connection: FakeSocketConnection, origin: String = "chrome-extension://abc"
  ) async -> String? {
    connection.feed(TestWebSocketClient.upgradeRequest(path: "/control", origin: origin))
    guard let response = await firstChunk(connection) else { return nil }
    return statusLine(response)
  }

  @Test("full control round trip: session.open dispatches to the handler and replies over WS")
  func fullRoundTrip() async throws {
    let handler = RecordingHandler()
    let (server, listener) = makeServer(allowedOrigins: ["chrome-extension://abc"], handler: handler)
    let runner = Task { await server.run() }
    let connection = FakeSocketConnection()
    listener.accept(connection)

    let status = await upgrade(connection)
    #expect(status?.contains("101") == true)

    let request = ControlRequest.sessionOpen(
      sources: ["browser:meet:jane"], slug: "meeting-uuid", start: nil, vocab: nil,
      trigger: .browserExtension)
    connection.feed(
      TestWebSocketClient.text(String(data: try JSONEncoder().encode(request), encoding: .utf8)!))

    guard let replyBytes = await firstChunk(connection),
      let frame = decodeServerFrame(replyBytes)
    else {
      Issue.record("no session.open reply")
      return
    }
    let reply = try JSONDecoder().decode(
      ControlResponse<SessionOpenData>.self, from: Data(frame.payload))
    guard case .success(let data) = reply else {
      Issue.record("expected session.open success")
      return
    }
    #expect(data.id == "2026-07-17T10-30-00Z_call")
    #expect(await handler.requests == [request])

    await server.shutdown()
    _ = await runner.value
  }

  @Test("meeting.resolve round-trips its meeting_id payload")
  func meetingResolveRoundTrip() async throws {
    let handler = RecordingHandler()
    let (server, listener) = makeServer(allowedOrigins: ["chrome-extension://abc"], handler: handler)
    let runner = Task { await server.run() }
    let connection = FakeSocketConnection()
    listener.accept(connection)
    _ = await upgrade(connection)

    connection.feed(
      TestWebSocketClient.text(#"{"cmd":"meeting.resolve","platform":"meet","external_id":"AbC"}"#))
    guard let replyBytes = await firstChunk(connection),
      let frame = decodeServerFrame(replyBytes)
    else {
      Issue.record("no meeting.resolve reply")
      return
    }
    let reply = try JSONDecoder().decode(
      ControlResponse<MeetingResolveData>.self, from: Data(frame.payload))
    guard case .success(let data) = reply else {
      Issue.record("expected meeting.resolve success")
      return
    }
    #expect(data.meetingID == "11111111-2222-3333-4444-555555555555")
    #expect(await handler.requests == [.meetingResolve(platform: "meet", externalID: "AbC")])

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
    let (server, listener) = makeServer(allowedOrigins: ["chrome-extension://abc"], handler: handler)
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

  @Test("subscribe transitions to event-stream mode and delivers matching events")
  func subscribeDeliversEvents() async throws {
    let handler = RecordingHandler()
    let (server, listener) = makeServer(allowedOrigins: ["chrome-extension://abc"], handler: handler)
    let runner = Task { await server.run() }
    let connection = FakeSocketConnection()
    listener.accept(connection)
    _ = await upgrade(connection)

    connection.feed(
      TestWebSocketClient.text(#"{"cmd":"subscribe","events":["session"],"sources":[]}"#))
    await wait { await server.subscriberCount == 1 }

    await server.publish(.session(id: "2026-07-17T10-30-00Z_call", state: .open))
    // A filtered-out kind must not be delivered.
    await server.publish(.vad(source: "mic", state: .speech, t: Instant(secondsSinceEpoch: 0)))

    guard let eventBytes = await firstChunk(connection),
      let frame = decodeServerFrame(eventBytes)
    else {
      Issue.record("no event frame")
      return
    }
    let event = try JSONDecoder().decode(EarsEvent.self, from: Data(frame.payload))
    #expect(event == .session(id: "2026-07-17T10-30-00Z_call", state: .open))

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

    connection.feed(
      TestWebSocketClient.text(#"{"cmd":"subscribe","events":["session"],"sources":[]}"#))
    await wait { await server.subscriberCount == 1 }
    await connection.stall()

    for i in 0..<10 {
      await server.publish(.session(id: "session-\(i)", state: .open))
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

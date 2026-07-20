import EarsCore
import Foundation
import Testing

@testable import EarsIPC

@Suite("ControlSocketServer (v2)")
struct ControlSocketServerTests {
  private static let identity = ControlServerIdentity(daemon: "earsd test", bootID: "boot-1")

  /// Reads framed lines from a connection's outbound stream until `count`
  /// have arrived.
  private func lines(_ connection: FakeSocketConnection, count: Int) async throws -> [Data] {
    var collected: [Data] = []
    for await chunk in connection.outbound {
      for line in LineFramerHelper.split(chunk) {
        collected.append(Data(line))
      }
      if collected.count >= count { return collected }
    }
    throw TestFailure.noOutput
  }

  private func firstLine(_ connection: FakeSocketConnection) async throws -> Data {
    try await lines(connection, count: 1)[0]
  }

  private func json(_ data: Data) throws -> [String: Any] {
    let object: [String: Any]? = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    return try #require(object)
  }

  /// Cooperatively yields until `condition` holds.
  private func wait(for condition: @Sendable () async -> Bool) async {
    while await condition() == false { await Task.yield() }
  }

  private func makeServer(
    listener: FakeSocketListener,
    outboundQueueBound: Int = ControlSocketServer.defaultOutboundQueueBound,
    handler: @escaping ControlHandler
  ) -> ControlSocketServer {
    ControlSocketServer(
      listener: listener, identity: Self.identity, outboundQueueBound: outboundQueueBound,
      handler: handler)
  }

  private func sendHello(_ connection: FakeSocketConnection, id: Int64 = 0) {
    connection.feedLine(
      ControlRequestFrame.hello(id: .int(id), params: HelloParams(client: "test/0")))
  }

  @Test("hello returns the identity and the full Unix-socket capability tier")
  func helloAdvertisesCapabilities() async throws {
    let listener = FakeSocketListener()
    let server = makeServer(listener: listener) { _ in .failure(.internalError, "no calls") }
    let runner = Task { await server.run() }
    let connection = FakeSocketConnection()
    listener.accept(connection)
    sendHello(connection)

    let frame = try await JSONDecoder().decode(
      ControlResponseFrame<HelloResult>.self, from: firstLine(connection))
    let result = try frame.get()
    #expect(frame.id == .int(0))
    #expect(result.protocolVersion == 2)
    #expect(result.bootID == "boot-1")
    #expect(Set(result.capabilities) == Capability.all)

    await server.shutdown()
    _ = await runner.value
  }

  @Test("anything before hello is refused with hello_required")
  func helloRequired() async throws {
    let listener = FakeSocketListener()
    let server = makeServer(listener: listener) { _ in .failure(.internalError, "no calls") }
    let runner = Task { await server.run() }
    let connection = FakeSocketConnection()
    listener.accept(connection)
    connection.feedLine(ControlRequestFrame.call(id: .int(5), call: .status))

    let frame = try await JSONDecoder().decode(
      ControlResponseFrame<EmptyData>.self, from: firstLine(connection))
    #expect(frame.id == .int(5))
    guard case .error(_, let error) = frame else {
      Issue.record("expected an error frame")
      return
    }
    #expect(error.code == .helloRequired)

    await server.shutdown()
    _ = await runner.value
  }

  @Test("an unsupported protocol version in hello is refused")
  func unsupportedProtocol() async throws {
    let listener = FakeSocketListener()
    let server = makeServer(listener: listener) { _ in .failure(.internalError, "no calls") }
    let runner = Task { await server.run() }
    let connection = FakeSocketConnection()
    listener.accept(connection)
    connection.feedLine(
      ControlRequestFrame.hello(id: .int(0), params: HelloParams(protocolVersion: 1)))

    let object = try json(try await firstLine(connection))
    let error: [String: Any]? = object["error"] as? [String: Any]
    #expect(try #require(error)["code"] as? String == "unsupported_protocol")

    await server.shutdown()
    _ = await runner.value
  }

  @Test("dispatches a request to the handler and writes back the id-correlated reply")
  func requestResponseRoundTrip() async throws {
    let listener = FakeSocketListener()
    let server = makeServer(listener: listener) { call in
      #expect(call == .status)
      return ControlReply(result: StatusData(uptimeSeconds: 7, sources: []))
    }
    let runner = Task { await server.run() }
    let connection = FakeSocketConnection()
    listener.accept(connection)
    sendHello(connection)
    connection.feedLine(ControlRequestFrame.call(id: .string("req-9"), call: .status))

    let replies = try await lines(connection, count: 2)
    let status = try JSONDecoder().decode(
      ControlResponseFrame<StatusData>.self, from: replies[1])
    #expect(status.id == .string("req-9"))
    #expect(try status.get().uptimeSeconds == 7)

    await server.shutdown()
    _ = await runner.value
  }

  @Test("an unknown method gets unknown_method; malformed JSON gets invalid_request")
  func malformedRequests() async throws {
    let listener = FakeSocketListener()
    let server = makeServer(listener: listener) { _ in .failure(.internalError, "no calls") }
    let runner = Task { await server.run() }
    let connection = FakeSocketConnection()
    listener.accept(connection)
    sendHello(connection)
    connection.feed(Array(#"{"id":1,"method":"meeting.resolve"}"#.utf8) + [0x0A])
    connection.feed(Array(#"{"nonsense":true}"#.utf8) + [0x0A])

    let replies = try await lines(connection, count: 3)
    let unknown = try json(replies[1])
    let unknownError: [String: Any]? = unknown["error"] as? [String: Any]
    #expect(try #require(unknownError)["code"] as? String == "unknown_method")
    let malformed = try json(replies[2])
    let malformedError: [String: Any]? = malformed["error"] as? [String: Any]
    #expect(try #require(malformedError)["code"] as? String == "invalid_request")
    #expect(malformed["id"] is NSNull)

    await server.shutdown()
    _ = await runner.value
  }

  @Test("subscribe registers the filter first, then returns the handler's snapshot")
  func subscribeRegistersThenSnapshots() async throws {
    let listener = FakeSocketListener()
    let server = makeServer(listener: listener) { call in
      guard case .subscribe = call else { return .failure(.internalError, "unexpected") }
      return ControlReply(
        result: SnapshotData(rev: 41, meetings: [], sources: [], sessions: []))
    }
    let runner = Task { await server.run() }
    let connection = FakeSocketConnection()
    listener.accept(connection)
    sendHello(connection)
    connection.feedLine(
      ControlRequestFrame.call(
        id: .int(1), call: .subscribe(SubscribeParams(events: [.vad], sources: ["mic"]))))

    let replies = try await lines(connection, count: 2)
    let snapshot = try JSONDecoder().decode(
      ControlResponseFrame<SnapshotData>.self, from: replies[1])
    #expect(try snapshot.get().rev == 41)
    #expect(await server.subscriberCount == 1)

    // Telemetry filter applies: wrong-source vad dropped, matching delivered,
    // and state events are always delivered regardless of the filter.
    await server.publish(
      EventFrame(event: .vad(source: "system", state: .speech, t: Instant(secondsSinceEpoch: 1))))
    await server.publish(
      EventFrame(event: .vad(source: "mic", state: .speech, t: Instant(secondsSinceEpoch: 2))))
    await server.publish(EventFrame(event: .source(id: "mic", state: .paused), rev: 42))

    let eventLines = try await lines(connection, count: 2)
    let delivered = try eventLines.map { try JSONDecoder().decode(EventFrame.self, from: $0) }
    #expect(
      delivered == [
        EventFrame(event: .vad(source: "mic", state: .speech, t: Instant(secondsSinceEpoch: 2))),
        EventFrame(event: .source(id: "mic", state: .paused), rev: 42),
      ])

    await server.shutdown()
    _ = await runner.value
  }

  @Test("a subscribed connection keeps answering requests — subscribing is not terminal")
  func subscribeNotTerminal() async throws {
    let listener = FakeSocketListener()
    let server = makeServer(listener: listener) { call in
      switch call {
      case .subscribe:
        return ControlReply(result: SnapshotData(rev: 0, meetings: [], sources: [], sessions: []))
      case .status:
        return ControlReply(result: StatusData(uptimeSeconds: 7, sources: []))
      default:
        return .failure(.internalError, "unexpected")
      }
    }
    let runner = Task { await server.run() }
    let connection = FakeSocketConnection()
    listener.accept(connection)
    sendHello(connection)
    connection.feedLine(
      ControlRequestFrame.call(id: .int(1), call: .subscribe(SubscribeParams())))
    connection.feedLine(ControlRequestFrame.call(id: .int(2), call: .status))

    let replies = try await lines(connection, count: 3)
    let status = try JSONDecoder().decode(
      ControlResponseFrame<StatusData>.self, from: replies[2])
    #expect(status.id == .int(2))
    #expect(try status.get().uptimeSeconds == 7)

    await server.shutdown()
    _ = await runner.value
  }

  @Test("events are not delivered to a connection that never subscribed")
  func noEventsWithoutSubscription() async throws {
    let listener = FakeSocketListener()
    let server = makeServer(listener: listener) { _ in .failure(.internalError, "no") }
    let runner = Task { await server.run() }
    let connection = FakeSocketConnection()
    listener.accept(connection)
    await wait { await server.connectionCount == 1 }

    await server.publish(EventFrame(event: .source(id: "mic", state: .paused), rev: 1))
    #expect(await server.droppedLineCount == 0)
    #expect(await server.subscriberCount == 0)

    await server.shutdown()
    _ = await runner.value
  }

  @Test("concurrent connections each get their own correct reply")
  func concurrentConnectionsDoNotCrossWires() async throws {
    // Echo the requested session id back as the uptime so each connection's
    // reply is uniquely identifiable; assert none get another's answer.
    let listener = FakeSocketListener()
    let server = makeServer(listener: listener) { call in
      guard case .sessionClose(let id) = call else {
        return .failure(.internalError, "unexpected")
      }
      return ControlReply(result: StatusData(uptimeSeconds: Int(id) ?? -1, sources: []))
    }
    let runner = Task { await server.run() }

    let connections = (0..<8).map { _ in FakeSocketConnection() }
    for connection in connections { listener.accept(connection) }
    for (index, connection) in connections.enumerated() {
      sendHello(connection)
      connection.feedLine(
        ControlRequestFrame.call(id: .int(1), call: .sessionClose(id: String(index))))
    }

    try await withThrowingTaskGroup(of: Void.self) { group in
      for (index, connection) in connections.enumerated() {
        group.addTask {
          let replies = try await self.lines(connection, count: 2)
          let status = try JSONDecoder().decode(
            ControlResponseFrame<StatusData>.self, from: replies[1])
          #expect(try status.get().uptimeSeconds == index)
        }
      }
      try await group.waitForAll()
    }

    await server.shutdown()
    _ = await runner.value
  }

  @Test("a stalled subscriber overflows its bounded queue and drops with a count")
  func stalledSubscriberDropsAndCounts() async throws {
    let bound = 8
    let listener = FakeSocketListener()
    let server = makeServer(listener: listener, outboundQueueBound: bound) { call in
      guard case .subscribe = call else { return .failure(.internalError, "no") }
      return ControlReply(result: SnapshotData(rev: 0, meetings: [], sources: [], sessions: []))
    }
    let runner = Task { await server.run() }
    // A connection whose send() never completes: a client that subscribes then
    // stops reading.
    let connection = FakeSocketConnection(stalled: true)
    listener.accept(connection)

    sendHello(connection)
    connection.feedLine(
      ControlRequestFrame.call(id: .int(1), call: .subscribe(SubscribeParams())))
    await wait { await server.subscriberCount == 1 }

    for i in 0..<(bound + 200) {
      await server.publish(
        EventFrame(event: .source(id: SourceID("s\(i)"), state: .paused), rev: i))
    }

    #expect(await server.droppedLineCount > 0)
    await server.shutdown()
    _ = await runner.value
  }

  @Test("shutdown closes accepted connections and ends the run loop")
  func shutdownClosesConnections() async throws {
    let listener = FakeSocketListener()
    let server = makeServer(listener: listener) { _ in .failure(.internalError, "x") }
    let runner = Task { await server.run() }
    let connection = FakeSocketConnection()
    listener.accept(connection)
    await wait { await server.connectionCount == 1 }

    await server.shutdown()
    _ = await runner.value

    #expect(await server.connectionCount == 0)
    // close() finished the connection's inbound stream; draining outbound ends.
    var chunks = 0
    for await _ in connection.outbound { chunks += 1 }
    #expect(chunks == 0)
  }
}

enum TestFailure: Error { case noOutput }

/// Splits raw outbound chunks on `\n` (the server writes one framed line per
/// `send`, but this keeps assertions robust to any coalescing).
enum LineFramerHelper {
  static func split(_ chunk: [UInt8]) -> [[UInt8]] {
    var framer = LineFramer()
    return framer.append(chunk)
  }
}

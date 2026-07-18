import EarsCore
import Foundation
import Testing

@testable import EarsIPC

@Suite("ControlSocketServer")
struct ControlSocketServerTests {
  /// Reads exactly one framed line from a connection's outbound stream.
  private func firstLine(_ connection: FakeSocketConnection) async throws -> Data {
    for await chunk in connection.outbound {
      if let line = LineFramerHelper.split(chunk).first { return Data(line) }
    }
    throw TestFailure.noOutput
  }

  private func decodeStatus(_ data: Data) throws -> ControlResponse<StatusData> {
    try JSONDecoder().decode(ControlResponse<StatusData>.self, from: data)
  }

  /// Cooperatively yields until `condition` holds. No wall-clock: it only
  /// relies on the readLoop task getting scheduled, which it will.
  private func wait(for condition: @Sendable () async -> Bool) async {
    while await condition() == false { await Task.yield() }
  }

  @Test("dispatches a request to the handler and writes back the reply")
  func requestResponseRoundTrip() async throws {
    let listener = FakeSocketListener()
    let server = ControlSocketServer(listener: listener) { request in
      #expect(request == .status)
      return ControlReply(ControlResponse.success(StatusData(uptimeSeconds: 7, sources: [])))
    }
    let runner = Task { await server.run() }
    let connection = FakeSocketConnection()
    listener.accept(connection)
    connection.feedLine(ControlRequest.status)

    let reply = try await decodeStatus(firstLine(connection))
    #expect(reply == .success(StatusData(uptimeSeconds: 7, sources: [])))

    await server.shutdown()
    _ = await runner.value
  }

  @Test("an unrecognised request line gets an error reply, not a crash")
  func malformedRequestGetsErrorReply() async throws {
    let listener = FakeSocketListener()
    let server = ControlSocketServer(listener: listener) { _ in
      ControlReply.failure("should not be called")
    }
    let runner = Task { await server.run() }
    let connection = FakeSocketConnection()
    listener.accept(connection)
    connection.feed(Array(#"{"cmd":"nonsense"}"#.utf8) + [0x0A])

    let reply = try await JSONDecoder().decode(
      ControlResponse<EmptyData>.self, from: firstLine(connection))
    guard case .failure = reply else {
      Issue.record("expected a failure reply")
      return
    }
    await server.shutdown()
    _ = await runner.value
  }

  @Test("a subscribed connection receives matching published events only")
  func subscribeReceivesFilteredEvents() async throws {
    let listener = FakeSocketListener()
    let server = ControlSocketServer(listener: listener) { _ in
      ControlReply.failure("no requests expected")
    }
    let runner = Task { await server.run() }
    let connection = FakeSocketConnection()
    listener.accept(connection)

    connection.feedLine(SubscribeRequest(events: [.vad], sources: ["mic"]))
    await wait { await server.subscriberCount == 1 }

    // Non-matching (wrong source), then matching.
    await server.publish(.vad(source: "system", state: .speech, t: Instant(secondsSinceEpoch: 1)))
    await server.publish(.vad(source: "mic", state: .speech, t: Instant(secondsSinceEpoch: 2)))

    var received: [EarsEvent] = []
    for await chunk in connection.outbound {
      for line in LineFramerHelper.split(chunk) {
        received.append(try JSONDecoder().decode(EarsEvent.self, from: Data(line)))
      }
      if received.count == 1 { break }
    }
    #expect(received == [.vad(source: "mic", state: .speech, t: Instant(secondsSinceEpoch: 2))])

    await server.shutdown()
    _ = await runner.value
  }

  @Test("events are not delivered to a connection that never subscribed")
  func noEventsWithoutSubscription() async throws {
    let listener = FakeSocketListener()
    let server = ControlSocketServer(listener: listener) { _ in ControlReply.failure("no") }
    let runner = Task { await server.run() }
    let connection = FakeSocketConnection()
    listener.accept(connection)
    await wait { await server.connectionCount == 1 }

    await server.publish(.session(id: "s1", state: .open))
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
    let server = ControlSocketServer(listener: listener) { request in
      guard case .sessionClose(let id) = request else { return ControlReply.failure("unexpected") }
      return ControlReply(
        ControlResponse.success(StatusData(uptimeSeconds: Int(id) ?? -1, sources: [])))
    }
    let runner = Task { await server.run() }

    let connections = (0..<8).map { _ in FakeSocketConnection() }
    for connection in connections { listener.accept(connection) }
    for (index, connection) in connections.enumerated() {
      connection.feedLine(ControlRequest.sessionClose(id: String(index)))
    }

    try await withThrowingTaskGroup(of: Void.self) { group in
      for (index, connection) in connections.enumerated() {
        group.addTask {
          let reply = try await self.decodeStatus(self.firstLine(connection))
          #expect(reply == .success(StatusData(uptimeSeconds: index, sources: [])))
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
    let server = ControlSocketServer(listener: listener, outboundQueueBound: bound) { _ in
      ControlReply.failure("no requests")
    }
    let runner = Task { await server.run() }
    // A connection whose send() never completes: a client that subscribes then
    // stops reading.
    let connection = FakeSocketConnection(stalled: true)
    listener.accept(connection)

    connection.feedLine(SubscribeRequest(events: [], sources: []))
    await wait { await server.subscriberCount == 1 }

    for i in 0..<(bound + 200) {
      await server.publish(.session(id: "s\(i)", state: .open))
    }

    #expect(await server.droppedLineCount > 0)
    await server.shutdown()
    _ = await runner.value
  }

  @Test("shutdown closes accepted connections and ends the run loop")
  func shutdownClosesConnections() async throws {
    let listener = FakeSocketListener()
    let server = ControlSocketServer(listener: listener) { _ in ControlReply.failure("x") }
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

import EarsCore
import Foundation
import Testing

@testable import EarsIPC

@Suite("ControlSocketClient")
struct ControlSocketClientTests {
  /// Simulates a server on the far end of a fake connection: reads each framed
  /// request line the client writes and calls `respond` to feed a reply back.
  private func serveRequests(
    on connection: FakeSocketConnection,
    respond: @escaping @Sendable (ControlRequest, FakeSocketConnection) -> Void
  ) -> Task<Void, Never> {
    Task {
      var framer = LineFramer()
      for await chunk in connection.outbound {
        for line in framer.append(chunk) {
          guard let request = try? JSONDecoder().decode(ControlRequest.self, from: Data(line))
          else { continue }
          respond(request, connection)
        }
      }
    }
  }

  @Test("send writes the request and decodes the typed response")
  func sendRoundTrip() async throws {
    let connection = FakeSocketConnection()
    let client = ControlSocketClient(connection: connection)
    let server = serveRequests(on: connection) { request, connection in
      #expect(request == .flush)
      connection.feedLine(ControlResponse.success(EmptyData()))
    }

    let response = try await client.send(.flush, expecting: EmptyData.self)
    #expect(response == .success(EmptyData()))
    server.cancel()
  }

  @Test("serialized sends stay correctly paired without a correlation id")
  func serializedSendsPairCorrectly() async throws {
    // The server echoes each request's session id back as the uptime. Because
    // send is actor-serialized, whichever request reaches the wire first reads
    // the first response, so each caller always gets its own answer even
    // though the protocol carries no request id.
    let connection = FakeSocketConnection()
    let client = ControlSocketClient(connection: connection)
    let server = serveRequests(on: connection) { request, connection in
      guard case .sessionClose(let id) = request else { return }
      connection.feedLine(
        ControlResponse.success(StatusData(uptimeSeconds: Int(id) ?? -1, sources: [])))
    }

    async let first = client.send(.sessionClose(id: "1"), expecting: StatusData.self)
    async let second = client.send(.sessionClose(id: "2"), expecting: StatusData.self)
    let (a, b) = try await (first, second)

    #expect(a == .success(StatusData(uptimeSeconds: 1, sources: [])))
    #expect(b == .success(StatusData(uptimeSeconds: 2, sources: [])))
    server.cancel()
  }

  @Test("send throws when the connection closes before a response arrives")
  func sendThrowsOnClosedConnection() async throws {
    let connection = FakeSocketConnection()
    let client = ControlSocketClient(connection: connection)
    await connection.close()

    await #expect(throws: (any Error).self) {
      _ = try await client.send(.flush, expecting: EmptyData.self)
    }
  }

  @Test("subscribe yields decoded events until the connection closes")
  func subscribeYieldsEvents() async throws {
    let connection = FakeSocketConnection()
    let client = ControlSocketClient(connection: connection)

    let events = try await client.subscribe(SubscribeRequest(events: [], sources: []))
    connection.feedLine(EarsEvent.session(id: "s1", state: .open))
    connection.feedLine(EarsEvent.session(id: "s1", state: .closed))

    var received: [EarsEvent] = []
    for await event in events {
      received.append(event)
      if received.count == 2 { break }
    }
    #expect(
      received == [
        .session(id: "s1", state: .open),
        .session(id: "s1", state: .closed),
      ])
    await client.close()
  }
}

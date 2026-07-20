import EarsCore
import Foundation
import Synchronization
import Testing

@testable import EarsIPC

@Suite("ControlSocketClient (v2)")
struct ControlSocketClientTests {
  /// Simulates a server on the far end of a fake connection: reads each framed
  /// request line the client writes and calls `respond` to feed a reply back.
  private func serveRequests(
    on connection: FakeSocketConnection,
    respond: @escaping @Sendable (ControlRequestFrame, FakeSocketConnection) -> Void
  ) -> Task<Void, Never> {
    Task {
      var framer = LineFramer()
      for await chunk in connection.outbound {
        for line in framer.append(chunk) {
          guard
            let frame = try? JSONDecoder().decode(ControlRequestFrame.self, from: Data(line))
          else { continue }
          respond(frame, connection)
        }
      }
    }
  }

  @Test("hello writes the handshake and decodes its result")
  func helloRoundTrip() async throws {
    let connection = FakeSocketConnection()
    let client = ControlSocketClient(connection: connection)
    let server = serveRequests(on: connection) { frame, connection in
      guard case .hello(let id, let params) = frame else {
        Issue.record("expected hello, got \(frame)")
        return
      }
      #expect(params.protocolVersion == 2)
      #expect(params.client == "test/1")
      connection.feedLine(
        ControlResponseFrame<HelloResult>.result(
          id: id,
          HelloResult(daemon: "earsd test", bootID: "boot-1", capabilities: [.observe])))
    }

    let result = try await client.hello(client: "test/1")
    #expect(result.bootID == "boot-1")
    server.cancel()
  }

  @Test("send decodes the typed result correlated by id")
  func sendRoundTrip() async throws {
    let connection = FakeSocketConnection()
    let client = ControlSocketClient(connection: connection)
    let server = serveRequests(on: connection) { frame, connection in
      guard case .call(let id, .flush) = frame else { return }
      connection.feedLine(ControlResponseFrame<EmptyData>.result(id: id, EmptyData()))
    }

    let response = try await client.send(.flush, expecting: EmptyData.self)
    #expect(response == EmptyData())
    server.cancel()
  }

  @Test("out-of-order responses still reach the right callers")
  func outOfOrderResponses() async throws {
    // The server holds every request until two have arrived, then answers
    // them in reverse — correlation ids, not arrival order, pair them.
    let connection = FakeSocketConnection()
    let client = ControlSocketClient(connection: connection)
    let held = Mutex<[(RequestID, String)]>([])
    let server = serveRequests(on: connection) { frame, connection in
      guard case .call(let id, .sessionClose(let sessionID)) = frame else { return }
      let ready: [(RequestID, String)]? = held.withLock { pending in
        pending.append((id, sessionID))
        return pending.count == 2 ? pending.reversed() : nil
      }
      for (heldID, heldSession) in ready ?? [] {
        connection.feedLine(
          ControlResponseFrame<StatusData>.result(
            id: heldID, StatusData(uptimeSeconds: Int(heldSession) ?? -1, sources: [])))
      }
    }

    async let first = client.send(.sessionClose(id: "1"), expecting: StatusData.self)
    async let second = client.send(.sessionClose(id: "2"), expecting: StatusData.self)
    let (a, b) = try await (first, second)

    #expect(a.uptimeSeconds == 1)
    #expect(b.uptimeSeconds == 2)
    server.cancel()
  }

  @Test("an error frame surfaces as a thrown WireError with its code")
  func errorFrameThrows() async throws {
    let connection = FakeSocketConnection()
    let client = ControlSocketClient(connection: connection)
    let server = serveRequests(on: connection) { frame, connection in
      guard case .call(let id, _) = frame else { return }
      connection.feedLine(
        ControlResponseFrame<EmptyData>.error(
          id: id, WireError(code: .meetingNotFound, message: "no active meeting m1")))
    }

    await #expect(throws: WireError(code: .meetingNotFound, message: "no active meeting m1")) {
      _ = try await client.send(.meetingPause(meeting: "m1"), expecting: EmptyData.self)
    }
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

  @Test("subscribe returns the snapshot, then yields events until the connection closes")
  func subscribeSnapshotAndEvents() async throws {
    let connection = FakeSocketConnection()
    let client = ControlSocketClient(connection: connection)
    let server = serveRequests(on: connection) { frame, connection in
      guard case .call(let id, .subscribe) = frame else { return }
      connection.feedLine(
        ControlResponseFrame<SnapshotData>.result(
          id: id, SnapshotData(rev: 41, meetings: [], sources: [], sessions: [])))
    }

    let (snapshot, events) = try await client.subscribe(SubscribeParams())
    #expect(snapshot.rev == 41)

    connection.feedLine(EventFrame(event: .source(id: "mic", state: .paused), rev: 42))
    connection.feedLine(
      EventFrame(event: .vad(source: "mic", state: .speech, t: Instant(secondsSinceEpoch: 1))))

    var received: [EventFrame] = []
    for await frame in events {
      received.append(frame)
      if received.count == 2 { break }
    }
    #expect(received[0].rev == 42)
    #expect(received[1].rev == nil)
    server.cancel()
    await client.close()
  }

  @Test("a subscribed connection still serves requests — one connection per frontend")
  func requestsAfterSubscribe() async throws {
    let connection = FakeSocketConnection()
    let client = ControlSocketClient(connection: connection)
    let server = serveRequests(on: connection) { frame, connection in
      switch frame {
      case .call(let id, .subscribe):
        connection.feedLine(
          ControlResponseFrame<SnapshotData>.result(
            id: id, SnapshotData(rev: 0, meetings: [], sources: [], sessions: [])))
      case .call(let id, .status):
        connection.feedLine(
          ControlResponseFrame<StatusData>.result(
            id: id, StatusData(uptimeSeconds: 7, sources: [])))
      default:
        break
      }
    }

    _ = try await client.subscribe(SubscribeParams())
    let status = try await client.send(.status, expecting: StatusData.self)
    #expect(status.uptimeSeconds == 7)
    server.cancel()
    await client.close()
  }
}

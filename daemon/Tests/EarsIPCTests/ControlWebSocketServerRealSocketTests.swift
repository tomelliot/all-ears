import EarsCore
import Foundation
import Network
import Testing

@testable import EarsIPC

/// The control-plane sibling of `IngestWebSocketServerRealSocketTests`: binds
/// a *real* `NetworkSocketListener` on an ephemeral loopback port and drives
/// `ControlWebSocketServer` over a real TCP socket — proving the handshake and
/// a command round trip work over real bytes, not just the in-memory fakes.
@Suite("ControlWebSocketServer (real loopback socket)")
struct ControlWebSocketServerRealSocketTests {
  /// Same minimal raw `NWConnection` client as the ingest suite's.
  private final class RawClient: @unchecked Sendable {
    let connection: NWConnection

    init(port: UInt16) async throws {
      connection = NWConnection(
        host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        connection.stateUpdateHandler = { state in
          switch state {
          case .ready: continuation.resume()
          case .failed(let error): continuation.resume(throwing: error)
          default: break
          }
        }
        connection.start(queue: .global())
      }
    }

    func send(_ bytes: [UInt8]) async throws {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        connection.send(
          content: Data(bytes),
          completion: .contentProcessed { error in
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
          })
      }
    }

    func receive() async throws -> [UInt8] {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<[UInt8], Error>) in
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
          if let error {
            continuation.resume(throwing: error)
          } else {
            continuation.resume(returning: data.map(Array.init) ?? [])
          }
        }
      }
    }

    func close() {
      connection.cancel()
    }
  }

  @Test("a real loopback client can complete the handshake and a control round trip")
  func realLoopbackRoundTrip() async throws {
    let listener = try await NetworkSocketListener.bind(toLoopbackPort: 0)
    guard let port = listener.boundPort, port != 0 else {
      Issue.record("listener did not report a bound port")
      return
    }

    actor Recorder {
      private(set) var calls: [ControlCall] = []
      func record(_ call: ControlCall) -> ControlReply {
        calls.append(call)
        return ControlReply(
          result: Meeting(
            id: "uuid-1", title: "meet x", state: .active,
            started: Instant(secondsSinceEpoch: 1), rev: 1))
      }
    }
    let recorder = Recorder()
    let server = ControlWebSocketServer(
      listener: listener,
      allowedOrigins: ["test-origin"],
      identity: ControlServerIdentity(daemon: "earsd test", bootID: "boot-real"),
      handler: { call in await recorder.record(call) })
    let runner = Task { await server.run() }

    let client = try await RawClient(port: port)
    try await client.send(
      TestWebSocketClient.upgradeRequest(path: "/control", origin: "test-origin"))
    let handshakeResponse = try await client.receive()
    #expect(statusLine(handshakeResponse)?.contains("101") == true)

    try await client.send(
      TestWebSocketClient.text(#"{"id":0,"method":"hello","params":{"protocol":2}}"#))
    guard let helloFrame = decodeServerFrame(try await client.receive()) else {
      Issue.record("no hello reply frame")
      return
    }
    let hello = try JSONDecoder().decode(
      ControlResponseFrame<HelloResult>.self, from: Data(helloFrame.payload))
    #expect(try hello.get().bootID == "boot-real")

    try await client.send(
      TestWebSocketClient.text(
        #"{"id":1,"method":"meeting.start","params":{"platform":"meet","external_id":"x"}}"#))
    let replyBytes = try await client.receive()
    guard let frame = decodeServerFrame(replyBytes) else {
      Issue.record("no decodable reply frame")
      return
    }
    let reply = try JSONDecoder().decode(
      ControlResponseFrame<Meeting>.self, from: Data(frame.payload))
    #expect(try reply.get().id == "uuid-1")
    #expect(
      await recorder.calls == [
        .meetingStart(MeetingStartParams(platform: "meet", externalID: "x"))
      ])

    client.close()
    await server.shutdown()
    _ = await runner.value
  }
}

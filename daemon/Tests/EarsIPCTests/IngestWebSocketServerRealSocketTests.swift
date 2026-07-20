import EarsCore
import Foundation
import Network
import Testing

@testable import EarsIPC

/// Unlike `IngestWebSocketServerTests.swift` (an in-memory `FakeSocketListener`/
/// `FakeSocketConnection`), this suite binds a *real* `NetworkSocketListener`
/// and connects to it over a real loopback TCP socket — the only way to
/// actually prove the "binds `127.0.0.1` only" requirement rather than just
/// assert it from reading the source. Ephemeral port (`0`) so tests never
/// collide with each other or a real running daemon.
@Suite("IngestWebSocketServer (real loopback socket)")
struct IngestWebSocketServerRealSocketTests {
  /// A minimal raw `NWConnection` client — no `SocketConnection` wrapper
  /// needed, this suite just needs to prove real bytes cross a real socket.
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

  @Test("a real loopback client can complete the handshake and an ingest round trip")
  func realLoopbackRoundTrip() async throws {
    let listener = try await NetworkSocketListener.bind(toLoopbackPort: 0)
    guard let port = listener.boundPort, port != 0 else {
      Issue.record("listener did not report a bound port")
      return
    }

    actor Sink {
      private(set) var opened: [String] = []
      func open(_ source: SourceID) -> String {
        opened.append(source.rawValue)
        return "s1"
      }
    }
    let sink = Sink()
    let server = IngestWebSocketServer(
      listener: listener,
      allowedOrigins: ["test-origin"],
      onOpen: { source, _ in await sink.open(source) },
      onPush: { _, _, _ in },
      onClose: { _ in })
    let runner = Task { await server.run() }

    let client = try await RawClient(port: port)
    try await client.send(TestWebSocketClient.upgradeRequest(origin: "test-origin"))
    let handshakeResponse = try await client.receive()
    #expect(statusLine(handshakeResponse)?.contains("101") == true)

    let format = AudioFormatSpec(sampleRate: 16000, channels: 1, encoding: "pcm_s16le")
    let openRequest = IngestRequest.open(
      source: "browser:meet:real-socket-test", format: format)
    let requestText = String(data: try JSONEncoder().encode(openRequest), encoding: .utf8)!
    try await client.send(TestWebSocketClient.text(requestText))

    let replyBytes = try await client.receive()
    guard let frame = decodeServerFrame(replyBytes) else {
      Issue.record("no decodable reply frame")
      return
    }
    let reply = try JSONDecoder().decode(
      ControlResponse<IngestOpenData>.self, from: Data(frame.payload))
    guard case .success(let data) = reply else {
      Issue.record("expected ingest.open success")
      return
    }
    #expect(data.streamID == "s1")
    #expect(await sink.opened == ["browser:meet:real-socket-test"])

    client.close()
    await server.shutdown()
    _ = await runner.value
  }
}

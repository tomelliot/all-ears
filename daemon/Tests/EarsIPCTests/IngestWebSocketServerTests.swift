import EarsCore
import Foundation
import Testing

@testable import EarsIPC

/// A minimal WebSocket *client* encoder — the test's stand-in for the
/// browser's real `WebSocket` API — for driving the real
/// `IngestWebSocketServer` at the byte level over a `FakeSocketConnection`
/// (this file) or a real loopback `NWConnection`
/// (`IngestWebSocketServerRealSocketTests.swift`). Not `private`: shared
/// across both files in this test target.
enum TestWebSocketClient {
  static func upgradeRequest(
    path: String = "/ingest", origin: String?, key: String = "dGhlIHNhbXBsZSBub25jZQ=="
  ) -> [UInt8] {
    var lines = [
      "GET \(path) HTTP/1.1",
      "Host: 127.0.0.1",
      "Upgrade: websocket",
      "Connection: Upgrade",
      "Sec-WebSocket-Key: \(key)",
      "Sec-WebSocket-Version: 13",
    ]
    if let origin { lines.append("Origin: \(origin)") }
    return Array((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
  }

  private static let maskKey: [UInt8] = [0x12, 0x34, 0x56, 0x78]

  static func maskedFrame(opcode: WebSocketOpcode, payload: [UInt8]) -> [UInt8] {
    var bytes: [UInt8] = [0x80 | opcode.rawValue]
    let length = payload.count
    if length <= 125 {
      bytes.append(0x80 | UInt8(length))
    } else if length <= 0xFFFF {
      bytes.append(0x80 | 126)
      bytes.append(UInt8((length >> 8) & 0xFF))
      bytes.append(UInt8(length & 0xFF))
    } else {
      bytes.append(0x80 | 127)
      for shift in stride(from: 56, through: 0, by: -8) {
        bytes.append(UInt8((UInt64(length) >> UInt64(shift)) & 0xFF))
      }
    }
    bytes.append(contentsOf: maskKey)
    var masked = payload
    for i in 0..<masked.count { masked[i] ^= maskKey[i % 4] }
    bytes.append(contentsOf: masked)
    return bytes
  }

  static func text(_ string: String) -> [UInt8] {
    maskedFrame(opcode: .text, payload: Array(string.utf8))
  }
  static func binary(_ bytes: [UInt8]) -> [UInt8] { maskedFrame(opcode: .binary, payload: bytes) }

  /// One ingest binary frame: `[u8 idLen][stream_id][pcm_s16le bytes]`.
  static func ingestBinaryFrame(streamID: String, pcm: [UInt8]) -> [UInt8] {
    let idBytes = Array(streamID.utf8)
    return binary([UInt8(idBytes.count)] + idBytes + pcm)
  }
}

/// Decodes ONE unmasked server→client frame, assuming it's fully present —
/// this suite's replies are small enough that a `FakeSocketConnection.send`
/// call (or one real-socket `recv`) always delivers a whole frame at once.
func decodeServerFrame(_ bytes: [UInt8]) -> WebSocketFrame? {
  guard bytes.count >= 2 else { return nil }
  let opcodeRaw = bytes[0] & 0x0F
  guard let opcode = WebSocketOpcode(rawValue: opcodeRaw) else { return nil }
  let lengthField = Int(bytes[1] & 0x7F)
  var offset = 2
  var payloadLength = lengthField
  if lengthField == 126 {
    guard bytes.count >= offset + 2 else { return nil }
    payloadLength = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
    offset += 2
  } else if lengthField == 127 {
    guard bytes.count >= offset + 8 else { return nil }
    var length: UInt64 = 0
    for i in 0..<8 { length = (length << 8) | UInt64(bytes[offset + i]) }
    offset += 8
    payloadLength = Int(length)
  }
  guard bytes.count >= offset + payloadLength else { return nil }
  return WebSocketFrame(opcode: opcode, payload: Array(bytes[offset..<(offset + payloadLength)]))
}

func statusLine(_ bytes: [UInt8]) -> String? {
  guard let text = String(bytes: bytes, encoding: .utf8) else { return nil }
  return text.components(separatedBy: "\r\n").first
}

/// Records handler calls so tests can assert on them without a real
/// `EarsDaemon`/`CaptureActor` — this suite is protocol-level, not
/// storage-level (that's `EarsDaemonKitTests`' job).
private actor RecordingIngestSink {
  private(set) var opened: [(source: String, format: AudioFormatSpec)] = []
  private(set) var pushed: [(streamID: String, samples: [Float], sampleRate: Int)] = []
  private(set) var closed: [String] = []
  var nextStreamID = 0
  var failOpen = false

  func open(_ source: SourceID, _ format: AudioFormatSpec) async throws -> String {
    opened.append((source.rawValue, format))
    if failOpen { throw TestIngestError.rejected }
    nextStreamID += 1
    return "s\(nextStreamID)"
  }

  func push(_ streamID: String, _ samples: [Float], _ sampleRate: Int) async {
    pushed.append((streamID, samples, sampleRate))
  }

  func close(_ streamID: String) async {
    closed.append(streamID)
  }
}

private enum TestIngestError: Error { case rejected }

@Suite("IngestWebSocketServer")
struct IngestWebSocketServerTests {
  private func wait(for condition: @Sendable () async -> Bool) async {
    while await condition() == false { await Task.yield() }
  }

  private func makeServer(
    allowedOrigins: [String], sink: RecordingIngestSink
  ) -> (IngestWebSocketServer, FakeSocketListener) {
    let listener = FakeSocketListener()
    let server = IngestWebSocketServer(
      listener: listener,
      allowedOrigins: allowedOrigins,
      onOpen: { source, format in try await sink.open(source, format) },
      onPush: { streamID, samples, rate in await sink.push(streamID, samples, rate) },
      onClose: { streamID in await sink.close(streamID) })
    return (server, listener)
  }

  @Test("allowed origin: full ingest.open -> binary push -> ingest.close round trip")
  func fullRoundTrip() async throws {
    let sink = RecordingIngestSink()
    let (server, listener) = makeServer(allowedOrigins: ["chrome-extension://abc"], sink: sink)
    let runner = Task { await server.run() }
    let connection = FakeSocketConnection()
    listener.accept(connection)

    connection.feed(TestWebSocketClient.upgradeRequest(origin: "chrome-extension://abc"))
    guard let response = await firstChunk(connection), let line = statusLine(response) else {
      Issue.record("no handshake response")
      return
    }
    #expect(line.contains("101"))

    let format = AudioFormatSpec(sampleRate: 16000, channels: 1, encoding: "pcm_s16le")
    let openRequest = ControlRequest.ingestOpen(source: "browser:meet:jane-a1b2", format: format)
    connection.feed(
      TestWebSocketClient.text(
        String(data: try JSONEncoder().encode(openRequest), encoding: .utf8)!))

    guard let openReplyBytes = await firstChunk(connection),
      let openFrame = decodeServerFrame(openReplyBytes)
    else {
      Issue.record("no ingest.open reply")
      return
    }
    let openReply = try JSONDecoder().decode(
      ControlResponse<IngestOpenData>.self, from: Data(openFrame.payload))
    guard case .success(let data) = openReply else {
      Issue.record("expected ingest.open success")
      return
    }
    #expect(data.streamID == "s1")

    // pcm_s16le: two little-endian Int16 samples, min and max.
    let pcmBytes: [UInt8] = [0x00, 0x80, 0xFF, 0x7F]  // -32768, 32767
    connection.feed(TestWebSocketClient.ingestBinaryFrame(streamID: data.streamID, pcm: pcmBytes))
    await wait { await sink.pushed.count == 1 }
    let pushed = await sink.pushed[0]
    #expect(pushed.streamID == "s1")
    #expect(pushed.sampleRate == 16000)
    #expect(pushed.samples.count == 2)
    #expect(abs(pushed.samples[0] - (-1.0)) < 0.001)
    #expect(abs(pushed.samples[1] - 0.99997) < 0.001)

    connection.feed(TestWebSocketClient.text(#"{"cmd":"ingest.close","stream_id":"s1"}"#))
    await wait { await sink.closed == ["s1"] }

    await server.shutdown()
    _ = await runner.value
  }

  @Test("disallowed origin gets 403 and no handshake")
  func disallowedOrigin() async throws {
    let sink = RecordingIngestSink()
    let (server, listener) = makeServer(allowedOrigins: ["chrome-extension://abc"], sink: sink)
    let runner = Task { await server.run() }
    let connection = FakeSocketConnection()
    listener.accept(connection)

    connection.feed(TestWebSocketClient.upgradeRequest(origin: "chrome-extension://evil"))
    guard let response = await firstChunk(connection), let line = statusLine(response) else {
      Issue.record("no response")
      return
    }
    #expect(line.contains("403"))
    #expect(await sink.opened.isEmpty)

    await server.shutdown()
    _ = await runner.value
  }

  @Test("an empty allowlist fails closed — rejects even a present Origin")
  func emptyAllowlistRejectsAll() async throws {
    let sink = RecordingIngestSink()
    let (server, listener) = makeServer(allowedOrigins: [], sink: sink)
    let runner = Task { await server.run() }
    let connection = FakeSocketConnection()
    listener.accept(connection)

    connection.feed(TestWebSocketClient.upgradeRequest(origin: "chrome-extension://abc"))
    guard let response = await firstChunk(connection), let line = statusLine(response) else {
      Issue.record("no response")
      return
    }
    #expect(line.contains("403"))

    await server.shutdown()
    _ = await runner.value
  }

  @Test("a non-ingest cmd is refused — the control plane stays on the Unix socket")
  func nonIngestCommandRefused() async throws {
    let sink = RecordingIngestSink()
    let (server, listener) = makeServer(allowedOrigins: ["chrome-extension://abc"], sink: sink)
    let runner = Task { await server.run() }
    let connection = FakeSocketConnection()
    listener.accept(connection)

    connection.feed(TestWebSocketClient.upgradeRequest(origin: "chrome-extension://abc"))
    _ = await firstChunk(connection)  // the 101 response

    connection.feed(TestWebSocketClient.text(#"{"cmd":"status"}"#))
    guard let replyBytes = await firstChunk(connection), let frame = decodeServerFrame(replyBytes)
    else {
      Issue.record("no reply")
      return
    }
    let reply = try JSONDecoder().decode(ControlResponse<EmptyData>.self, from: Data(frame.payload))
    guard case .failure = reply else {
      Issue.record("expected a failure reply for a non-ingest cmd")
      return
    }

    await server.shutdown()
    _ = await runner.value
  }

  @Test("a malformed binary frame (idLen past end) is dropped, not a crash")
  func malformedBinaryFrameDropped() async throws {
    let sink = RecordingIngestSink()
    let (server, listener) = makeServer(allowedOrigins: ["chrome-extension://abc"], sink: sink)
    let runner = Task { await server.run() }
    let connection = FakeSocketConnection()
    listener.accept(connection)

    connection.feed(TestWebSocketClient.upgradeRequest(origin: "chrome-extension://abc"))
    _ = await firstChunk(connection)  // the 101 response

    // idLen = 200, but only 1 byte of payload follows — malformed.
    connection.feed(TestWebSocketClient.binary([200, 0x41]))

    // The connection must still be alive and usable afterwards.
    let format = AudioFormatSpec(sampleRate: 16000, channels: 1, encoding: "pcm_s16le")
    let openRequest = ControlRequest.ingestOpen(source: "browser:meet:jane", format: format)
    connection.feed(
      TestWebSocketClient.text(
        String(data: try JSONEncoder().encode(openRequest), encoding: .utf8)!))
    await wait { await sink.opened.count == 1 }

    await server.shutdown()
    _ = await runner.value
  }

  @Test("an unknown path gets 404")
  func unknownPath() async throws {
    let sink = RecordingIngestSink()
    let (server, listener) = makeServer(allowedOrigins: ["chrome-extension://abc"], sink: sink)
    let runner = Task { await server.run() }
    let connection = FakeSocketConnection()
    listener.accept(connection)

    connection.feed(
      TestWebSocketClient.upgradeRequest(path: "/other", origin: "chrome-extension://abc"))
    guard let response = await firstChunk(connection), let line = statusLine(response) else {
      Issue.record("no response")
      return
    }
    #expect(line.contains("404"))

    await server.shutdown()
    _ = await runner.value
  }

  private func firstChunk(_ connection: FakeSocketConnection) async -> [UInt8]? {
    for await chunk in connection.outbound { return chunk }
    return nil
  }
}

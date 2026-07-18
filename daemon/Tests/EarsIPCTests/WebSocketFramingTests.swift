import Foundation
import Testing

@testable import EarsIPC

@Suite("HTTPHandshakeReader")
struct HTTPHandshakeReaderTests {
  @Test("parses a request split across multiple append() calls, exposing leftover bytes")
  func splitAcrossCalls() {
    var reader = HTTPHandshakeReader()
    let request =
      "GET /ingest HTTP/1.1\r\n"
      + "Host: 127.0.0.1\r\n"
      + "Origin: chrome-extension://abc\r\n"
      + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
    let bytes = Array(request.utf8)
    let firstHalf = Array(bytes[0..<20])
    let secondHalf = Array(bytes[20...]) + [0xAA, 0xBB]  // + a fake first WS frame byte

    #expect(reader.append(firstHalf) == nil)
    guard let head = reader.append(secondHalf) else {
      Issue.record("expected a parsed head")
      return
    }
    #expect(head.method == "GET")
    #expect(head.path == "/ingest")
    #expect(head.headers["origin"] == "chrome-extension://abc")
    #expect(head.headers["sec-websocket-key"] == "dGhlIHNhbXBsZSBub25jZQ==")
    #expect(reader.leftoverBytes == [0xAA, 0xBB])
    #expect(!reader.isMalformed)
  }

  @Test("header names are matched case-insensitively")
  func caseInsensitiveHeaders() {
    var reader = HTTPHandshakeReader()
    let request = "GET /ingest HTTP/1.1\r\nORIGIN: x\r\nSEC-WEBSOCKET-KEY: y\r\n\r\n"
    let head = reader.append(Array(request.utf8))
    #expect(head?.headers["origin"] == "x")
    #expect(head?.headers["sec-websocket-key"] == "y")
  }

  @Test("an oversized header block is flagged malformed rather than buffered forever")
  func oversizedIsMalformed() {
    var reader = HTTPHandshakeReader()
    let junk = [UInt8](repeating: 0x41, count: 9000)
    _ = reader.append(junk)
    #expect(reader.isMalformed)
  }
}

@Suite("WebSocketHandshake")
struct WebSocketHandshakeTests {
  @Test("matches RFC 6455 §1.3's own worked example")
  func rfcExample() {
    #expect(
      WebSocketHandshake.acceptKey(forKey: "dGhlIHNhbXBsZSBub25jZQ==")
        == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
  }
}

@Suite("WebSocketFrameReader")
struct WebSocketFrameReaderTests {
  private func maskedFrame(fin: Bool = true, opcode: WebSocketOpcode, payload: [UInt8]) -> [UInt8] {
    let maskKey: [UInt8] = [0x12, 0x34, 0x56, 0x78]
    var bytes: [UInt8] = [(fin ? 0x80 : 0x00) | opcode.rawValue]
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

  @Test("unmasks a small text frame")
  func smallTextFrame() {
    var reader = WebSocketFrameReader()
    let frames = reader.append(maskedFrame(opcode: .text, payload: Array("hi".utf8)))
    #expect(frames.count == 1)
    #expect(frames.first?.opcode == .text)
    #expect(String(bytes: frames.first?.payload ?? [], encoding: .utf8) == "hi")
  }

  @Test("handles the 126 extended-length header (a real ~3.2 KB PCM frame)")
  func extendedLength() {
    var reader = WebSocketFrameReader()
    let payload = [UInt8](repeating: 0x7, count: 3200)
    let frames = reader.append(maskedFrame(opcode: .binary, payload: payload))
    #expect(frames.count == 1)
    #expect(frames.first?.payload == payload)
  }

  @Test("an unmasked client frame is a protocol error, not silently accepted")
  func unmaskedFrameIsProtocolError() {
    var reader = WebSocketFrameReader()
    // FIN=1, opcode=text, MASK bit unset, length=2, raw payload.
    let unmasked: [UInt8] = [0x81, 0x02, 0x68, 0x69]
    let frames = reader.append(unmasked)
    #expect(frames.isEmpty)
    #expect(reader.protocolError)
  }

  @Test("reassembles a fragmented message across continuation frames")
  func fragmentedMessage() {
    var reader = WebSocketFrameReader()
    var frames = reader.append(maskedFrame(fin: false, opcode: .text, payload: Array("hel".utf8)))
    #expect(frames.isEmpty)
    frames = reader.append(maskedFrame(fin: true, opcode: .continuation, payload: Array("lo".utf8)))
    #expect(frames.count == 1)
    #expect(String(bytes: frames.first?.payload ?? [], encoding: .utf8) == "hello")
    #expect(!reader.protocolError)
  }

  @Test("a bare continuation frame with nothing to continue is a protocol error")
  func bareContinuationIsProtocolError() {
    var reader = WebSocketFrameReader()
    let frames = reader.append(maskedFrame(opcode: .continuation, payload: [0x01]))
    #expect(frames.isEmpty)
    #expect(reader.protocolError)
  }

  @Test("splits two frames delivered in one chunk")
  func twoFramesOneChunk() {
    var reader = WebSocketFrameReader()
    let combined =
      maskedFrame(opcode: .text, payload: Array("a".utf8))
      + maskedFrame(opcode: .text, payload: Array("b".utf8))
    let frames = reader.append(combined)
    #expect(frames.count == 2)
    #expect(String(bytes: frames[0].payload, encoding: .utf8) == "a")
    #expect(String(bytes: frames[1].payload, encoding: .utf8) == "b")
  }
}

@Suite("WebSocketFrameWriter")
struct WebSocketFrameWriterTests {
  @Test("encodes a server text frame unmasked, decodable by a plain reader")
  func textFrameIsUnmasked() {
    let bytes = WebSocketFrameWriter.text("hello")
    #expect(bytes[0] == 0x81)  // FIN=1, opcode=text
    #expect(bytes[1] & 0x80 == 0)  // server frames are never masked
    #expect(Array(bytes[2...]) == Array("hello".utf8))
  }

  @Test("close frame carries the given status code")
  func closeFrameCode() {
    let bytes = WebSocketFrameWriter.close(code: 1000)
    #expect(bytes[0] == 0x88)
    #expect(bytes.suffix(2) == [0x03, 0xE8])
  }
}

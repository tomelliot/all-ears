import CryptoKit
import Foundation

/// One parsed HTTP/1.1 request line + headers (the WebSocket upgrade
/// handshake `GET /ingest HTTP/1.1 ...`). Header names are lowercased on
/// parse so lookups are case-insensitive, per RFC 7230.
struct HTTPRequestHead: Sendable {
  var method: String
  var path: String
  var headers: [String: String]
}

/// Stateful incremental parser for the HTTP request head that precedes a
/// WebSocket upgrade. `IngestWebSocketServer` must inspect the request path
/// and `Origin` header *before* completing the upgrade (Network.framework's
/// `NWProtocolWebSocket` gives no such hook on the server role, which is why
/// this handshake is hand-rolled directly on raw bytes — see this file's
/// sibling `IngestWebSocketServer`).
///
/// Mirrors ``LineFramer``'s shape: feed bytes via ``append(_:)`` as they
/// arrive; it buffers until the `\r\n\r\n` header terminator is seen, then
/// returns the parsed head once, with any bytes past the terminator (the
/// start of the client's first WebSocket frame) left in ``leftoverBytes``.
struct HTTPHandshakeReader: Sendable {
  /// Bounds how much a client can make this buffer before it's rejected as
  /// malformed — a real browser's upgrade request is well under 1 KB.
  private static let maxHeaderBytes = 8192
  private static let terminator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]

  private var buffer: [UInt8] = []
  private(set) var isMalformed = false
  /// Bytes received after the header terminator — the start of the first
  /// WebSocket frame — populated once ``append(_:)`` returns a non-nil head.
  private(set) var leftoverBytes: [UInt8] = []

  /// Feeds newly-received bytes in. Returns the parsed request head once the
  /// terminator has been seen; `nil` while more bytes are still needed, or
  /// once ``isMalformed`` is set (oversized buffer, or a terminator that
  /// doesn't parse as a valid request line).
  mutating func append(_ bytes: [UInt8]) -> HTTPRequestHead? {
    guard !isMalformed else { return nil }
    buffer.append(contentsOf: bytes)
    if buffer.count > Self.maxHeaderBytes {
      isMalformed = true
      return nil
    }
    guard let terminatorIndex = Self.firstOccurrence(of: Self.terminator, in: buffer) else {
      return nil
    }
    let headerBytes = Array(buffer[buffer.startIndex..<terminatorIndex])
    leftoverBytes = Array(buffer[(terminatorIndex + Self.terminator.count)...])
    buffer = []

    guard let head = Self.parseHead(headerBytes) else {
      isMalformed = true
      return nil
    }
    return head
  }

  private static func parseHead(_ headerBytes: [UInt8]) -> HTTPRequestHead? {
    guard let text = String(bytes: headerBytes, encoding: .utf8) else { return nil }
    let lines = text.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return nil }
    let parts = requestLine.split(separator: " ")
    guard parts.count >= 2 else { return nil }

    var headers: [String: String] = [:]
    for line in lines.dropFirst() where !line.isEmpty {
      guard let colonIndex = line.firstIndex(of: ":") else { continue }
      let name = line[line.startIndex..<colonIndex].trimmingCharacters(in: .whitespaces)
        .lowercased()
      let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
      headers[name] = value
    }
    return HTTPRequestHead(method: String(parts[0]), path: String(parts[1]), headers: headers)
  }

  private static func firstOccurrence(of pattern: [UInt8], in bytes: [UInt8]) -> Int? {
    guard bytes.count >= pattern.count else { return nil }
    for i in 0...(bytes.count - pattern.count) {
      if Array(bytes[i..<(i + pattern.count)]) == pattern { return i }
    }
    return nil
  }
}

/// Plain-text HTTP responses for the handshake path — either the `101`
/// upgrade or a rejection (`400`/`403`/`404`) that closes the connection
/// without ever completing the WebSocket handshake.
enum HTTPResponseBuilder {
  static func switchingProtocols(acceptKey: String) -> [UInt8] {
    Array(
      ("HTTP/1.1 101 Switching Protocols\r\n"
        + "Upgrade: websocket\r\n"
        + "Connection: Upgrade\r\n"
        + "Sec-WebSocket-Accept: \(acceptKey)\r\n\r\n").utf8)
  }

  static func error(status: Int, reason: String) -> [UInt8] {
    Array(
      ("HTTP/1.1 \(status) \(reason)\r\n"
        + "Connection: close\r\n"
        + "Content-Length: 0\r\n\r\n").utf8)
  }
}

/// RFC 6455 §1.3's `Sec-WebSocket-Accept` computation: base64 of the SHA-1
/// digest of the client's `Sec-WebSocket-Key` concatenated with the
/// protocol's fixed magic GUID. SHA-1 here is protocol conformance, not a
/// security-sensitive hash, hence `Insecure.SHA1`.
enum WebSocketHandshake {
  private static let magicGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  static func acceptKey(forKey key: String) -> String {
    let digest = Insecure.SHA1.hash(data: Data((key + magicGUID).utf8))
    return Data(digest).base64EncodedString()
  }
}

/// One decoded WebSocket message — already unmasked and, for a fragmented
/// message, fully reassembled across its continuation frames. `opcode` is
/// always `.text`, `.binary`, `.close`, `.ping`, or `.pong` (never
/// `.continuation`, which ``WebSocketFrameReader`` folds into the message it
/// continues).
struct WebSocketFrame: Sendable {
  var opcode: WebSocketOpcode
  var payload: [UInt8]
}

enum WebSocketOpcode: UInt8, Sendable {
  case continuation = 0x0
  case text = 0x1
  case binary = 0x2
  case close = 0x8
  case ping = 0x9
  case pong = 0xA
}

/// Stateful incremental RFC 6455 frame parser/reassembler, mirroring
/// ``LineFramer``'s "feed bytes, get back complete units" shape.
///
/// - Unmasks every frame: RFC 6455 §5.1 requires every client→server frame
///   be masked; an unmasked frame is a protocol violation and sets
///   ``protocolError`` (the caller closes the connection).
/// - Reassembles fragmented messages (`FIN=0` continuation frames per
///   §5.4) into one ``WebSocketFrame``; control frames (close/ping/pong)
///   are never fragmented and are surfaced as soon as their one frame
///   completes, even mid-reassembly of a data message.
struct WebSocketFrameReader: Sendable {
  private var buffer: [UInt8] = []
  private(set) var protocolError = false

  private var fragmentedOpcode: WebSocketOpcode?
  private var fragmentedPayload: [UInt8] = []

  private struct RawFrame {
    var fin: Bool
    var opcode: UInt8
    var masked: Bool
    var payload: [UInt8]
  }

  /// Feeds newly-received bytes in and returns any messages completed as a
  /// result, in order. Once ``protocolError`` is set, further calls return
  /// nothing — the caller is expected to close the connection.
  mutating func append(_ bytes: [UInt8]) -> [WebSocketFrame] {
    guard !protocolError else { return [] }
    buffer.append(contentsOf: bytes)

    var completed: [WebSocketFrame] = []
    while true {
      guard let (raw, consumed) = parseOne() else { break }
      buffer.removeFirst(consumed)
      guard raw.masked else {
        // RFC 6455 §5.1: the server MUST close the connection upon receiving
        // an unmasked frame from a client.
        protocolError = true
        break
      }
      if let frame = fold(raw) { completed.append(frame) }
    }
    return completed
  }

  private mutating func fold(_ raw: RawFrame) -> WebSocketFrame? {
    guard let opcode = WebSocketOpcode(rawValue: raw.opcode) else {
      protocolError = true
      return nil
    }
    switch opcode {
    case .close, .ping, .pong:
      guard raw.fin else {
        protocolError = true  // control frames must not be fragmented
        return nil
      }
      return WebSocketFrame(opcode: opcode, payload: raw.payload)
    case .continuation:
      guard let started = fragmentedOpcode else {
        protocolError = true  // continuation with nothing to continue
        return nil
      }
      fragmentedPayload.append(contentsOf: raw.payload)
      guard raw.fin else { return nil }
      defer {
        fragmentedOpcode = nil
        fragmentedPayload = []
      }
      return WebSocketFrame(opcode: started, payload: fragmentedPayload)
    case .text, .binary:
      guard raw.fin else {
        fragmentedOpcode = opcode
        fragmentedPayload = raw.payload
        return nil
      }
      return WebSocketFrame(opcode: opcode, payload: raw.payload)
    }
  }

  /// Parses one frame from the front of `buffer` if a complete frame is
  /// available, returning it plus how many bytes it consumed. `nil` means
  /// more bytes are needed — the buffer is left untouched.
  private func parseOne() -> (RawFrame, Int)? {
    guard buffer.count >= 2 else { return nil }
    let b0 = buffer[0]
    let b1 = buffer[1]
    let fin = (b0 & 0x80) != 0
    let opcode = b0 & 0x0F
    let masked = (b1 & 0x80) != 0
    let lengthField = Int(b1 & 0x7F)
    var offset = 2

    let payloadLength: Int
    if lengthField == 126 {
      guard buffer.count >= offset + 2 else { return nil }
      payloadLength = Int(buffer[offset]) << 8 | Int(buffer[offset + 1])
      offset += 2
    } else if lengthField == 127 {
      guard buffer.count >= offset + 8 else { return nil }
      var length: UInt64 = 0
      for i in 0..<8 { length = (length << 8) | UInt64(buffer[offset + i]) }
      offset += 8
      payloadLength = Int(length)
    } else {
      payloadLength = lengthField
    }

    var maskKey: [UInt8] = []
    if masked {
      guard buffer.count >= offset + 4 else { return nil }
      maskKey = Array(buffer[offset..<(offset + 4)])
      offset += 4
    }

    guard buffer.count >= offset + payloadLength else { return nil }
    var payload = Array(buffer[offset..<(offset + payloadLength)])
    if masked {
      for i in 0..<payload.count { payload[i] ^= maskKey[i % 4] }
    }
    return (
      RawFrame(fin: fin, opcode: opcode, masked: masked, payload: payload), offset + payloadLength
    )
  }
}

/// Encodes outgoing (server→client) frames — always unmasked, per RFC 6455
/// §5.1 (masking is a client-to-server-only requirement).
enum WebSocketFrameWriter {
  static func text(_ string: String) -> [UInt8] {
    encode(opcode: .text, payload: Array(string.utf8))
  }

  static func binary(_ bytes: [UInt8]) -> [UInt8] {
    encode(opcode: .binary, payload: bytes)
  }

  static func close(code: UInt16 = 1000) -> [UInt8] {
    encode(opcode: .close, payload: [UInt8(code >> 8), UInt8(code & 0xFF)])
  }

  static func pong(payload: [UInt8]) -> [UInt8] {
    encode(opcode: .pong, payload: payload)
  }

  private static func encode(opcode: WebSocketOpcode, payload: [UInt8]) -> [UInt8] {
    var bytes: [UInt8] = [0x80 | opcode.rawValue]  // FIN=1, no fragmentation on writes
    let length = payload.count
    if length <= 125 {
      bytes.append(UInt8(length))
    } else if length <= 0xFFFF {
      bytes.append(126)
      bytes.append(UInt8((length >> 8) & 0xFF))
      bytes.append(UInt8(length & 0xFF))
    } else {
      bytes.append(127)
      for shift in stride(from: 56, through: 0, by: -8) {
        bytes.append(UInt8((UInt64(length) >> UInt64(shift)) & 0xFF))
      }
    }
    bytes.append(contentsOf: payload)
    return bytes
  }
}

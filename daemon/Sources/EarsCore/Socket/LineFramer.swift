import Foundation

/// Stateful newline-delimited-JSON framer for the control socket.
///
/// A single `recv()` can return a fragment of one JSON line, exactly one
/// line, or several lines concatenated. `LineFramer` normalises all three
/// into a stream of complete lines: feed it raw bytes as they arrive via
/// ``append(_:)``, and it returns any lines newly completed by that call,
/// retaining a trailing incomplete fragment internally for the next one.
///
/// `LineFramer` is deliberately JSON-agnostic: it splits on `\n` only and
/// never inspects line contents. A line that turns out not to be valid JSON
/// is still emitted whole, exactly like any complete line — detecting and
/// handling malformed JSON is the decoding layer's job (mirroring
/// ``IndexLog``'s skip-and-report precedent for `index.jsonl`), not the
/// framer's. This keeps the byte-framing state machine simple and testable
/// independent of the wire schema, and is what a later `EarsIPC` shim feeds
/// real socket-read bytes into.
public struct LineFramer: Sendable {
  private var buffer: [UInt8] = []

  public init() {}

  /// Bytes received but not yet terminated by a newline.
  public var pendingFragment: [UInt8] { buffer }

  /// Feeds newly-received bytes in and returns any lines completed as a
  /// result, in order, with the trailing `\n` stripped from each. Bytes
  /// after the last `\n` (if any) are retained in ``pendingFragment`` for
  /// the next call.
  public mutating func append(_ bytes: [UInt8]) -> [[UInt8]] {
    guard !bytes.isEmpty else { return [] }
    buffer.append(contentsOf: bytes)

    var lines: [[UInt8]] = []
    while let newlineIndex = buffer.firstIndex(of: 0x0A) {
      lines.append(Array(buffer[buffer.startIndex..<newlineIndex]))
      buffer.removeSubrange(buffer.startIndex...newlineIndex)
    }
    return lines
  }

  /// Encodes `value` as a single newline-terminated JSON line, the inverse
  /// of the framing ``append(_:)`` performs — for writing a request,
  /// response, or event to the socket.
  public static func encodeLine<T: Encodable>(
    _ value: T,
    using encoder: JSONEncoder = JSONEncoder()
  ) throws -> [UInt8] {
    var data = try encoder.encode(value)
    data.append(0x0A)
    return Array(data)
  }
}

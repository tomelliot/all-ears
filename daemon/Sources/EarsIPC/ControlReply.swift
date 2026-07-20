import EarsCore
import Foundation

/// A type-erased v2 reply, the value a request handler hands back to the
/// control transports for writing.
///
/// The wire response envelope is uniform — `{"id":…,"result":…}` or
/// `{"id":…,"error":{"code":…,"message":…}}` — but result payloads differ
/// per method, and a single handler signature can't name every concrete
/// `ControlResponseFrame<Payload>`. `ControlReply` erases the payload: it
/// captures the typed result (or a ``WireError``) and remembers only how to
/// encode the frame once the transport supplies the request's echoed `id`.
public struct ControlReply: Sendable {
  private let encodeFrame: @Sendable (RequestID, JSONEncoder) throws -> Data

  /// Wraps a typed success result.
  public init<Payload: Codable & Sendable & Hashable>(result: Payload) {
    self.encodeFrame = { id, encoder in
      try encoder.encode(ControlResponseFrame<Payload>.result(id: id, result))
    }
  }

  /// Wraps a failure.
  public init(error: WireError) {
    self.encodeFrame = { id, encoder in
      try encoder.encode(ControlResponseFrame<EmptyData>.error(id: id, error))
    }
  }

  /// Convenience failure constructor.
  public static func failure(_ code: ControlErrorCode, _ message: String) -> ControlReply {
    ControlReply(error: WireError(code: code, message: message))
  }

  /// The reply's JSON frame for the request identified by `id`, without a
  /// trailing newline.
  public func encoded(id: RequestID, using encoder: JSONEncoder) throws -> Data {
    try encodeFrame(id, encoder)
  }
}

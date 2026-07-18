import EarsCore
import Foundation

/// A type-erased control-socket reply, the value a request handler hands back
/// to ``ControlSocketServer`` for writing.
///
/// The wire response envelope is uniform across all fourteen commands —
/// `{"ok":true,"data":<payload>}` or `{"ok":false,"error":"<message>"}` — but
/// ``ControlResponse`` is generic over its payload type (`ControlResponse<StatusData>`
/// for `status`, `ControlResponse<EmptyData>` for `flush`, and so on). A single
/// handler signature that dispatches *every* command therefore cannot name one
/// concrete payload type. `ControlReply` erases the payload: it captures a
/// typed ``ControlResponse`` and remembers only how to encode its envelope, so
/// the transport writes any command's reply through one code path. This is why
/// the server handler is `(ControlRequest) async -> ControlReply` rather than
/// the (non-compiling) `-> ControlResponse` the task sketched.
public struct ControlReply: Sendable {
  private let encodeEnvelope: @Sendable (JSONEncoder) throws -> Data

  /// Wraps a typed response. `Payload: Sendable` makes the captured value safe
  /// to hold in the `@Sendable` encoding closure.
  public init<Payload>(_ response: ControlResponse<Payload>) {
    self.encodeEnvelope = { encoder in try encoder.encode(response) }
  }

  /// A failure envelope (`{"ok":false,"error":...}`) — the payload type is
  /// irrelevant on the wire for failures, so this fixes it to ``EmptyData``.
  /// Used by the server for protocol-level errors (an undecodable request)
  /// that arise before any handler runs.
  public static func failure(_ error: ControlError) -> ControlReply {
    ControlReply(ControlResponse<EmptyData>.failure(error))
  }

  /// The reply's JSON envelope, without a trailing newline.
  public func encoded(using encoder: JSONEncoder) throws -> Data {
    try encodeEnvelope(encoder)
  }
}

/// The byte-transport seam the control-socket server and client are built on,
/// mirroring `EarsCore`'s small-protocol/mockable-conformance house style
/// (`CaptureBackend`, `VAD`). Splitting the raw byte plumbing behind these two
/// protocols lets the framing, dispatch, and pub/sub-fan-out logic in
/// ``ControlSocketServer`` be unit-tested against an in-memory fake with no
/// real file descriptors, while ``NetworkSocketListener`` provides the real
/// Unix-domain-socket conformance exercised end-to-end.
///
/// The seam is deliberately JSON-agnostic and framing-agnostic: it moves
/// opaque byte chunks, exactly as a socket `recv`/`send` does. Newline framing
/// (via ``LineFramer``) and wire decoding live one layer up.

/// One accepted connection: an inbound byte stream plus a serialized outbound
/// write. A connection is single-consumer on ``inbound`` and single-writer on
/// ``send(_:)`` — the server/client dedicate one task to each direction.
public protocol SocketConnection: Sendable {
  /// Bytes as they arrive from the peer, in order. The stream finishes when
  /// the peer closes the connection or it fails — that finish is the sole
  /// end-of-connection signal the layers above rely on.
  var inbound: AsyncStream<[UInt8]> { get }

  /// Write `bytes` to the peer, resuming once they are handed to the
  /// transport. Throws if the connection is closed or the write fails. The
  /// caller serializes writes (one outbound task per connection), so byte
  /// order on the wire is well-defined.
  func send(_ bytes: [UInt8]) async throws

  /// Close the connection. Idempotent; safe to call more than once.
  func close() async
}

/// A listening socket that yields one ``SocketConnection`` per accepted client.
public protocol SocketListener: Sendable {
  /// Accepted connections, in arrival order, until the listener is closed via
  /// ``close()`` (which finishes the stream).
  var connections: AsyncStream<any SocketConnection> { get }

  /// Stop listening and finish ``connections``. Idempotent. Does not itself
  /// close already-accepted connections — the server owns their lifecycle.
  func close() async
}

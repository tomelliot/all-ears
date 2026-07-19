import EarsCore
import Foundation

@testable import EarsIPC

// In-memory `SocketConnection`/`SocketListener` conformances for exercising the
// framing, dispatch, and pub/sub fan-out in `ControlSocketServer`/
// `ControlSocketClient` with no real file descriptors.
//
// These live in the test target rather than `EarsCoreTestSupport` because the
// seam they implement (`SocketConnection`/`SocketListener`) lives in `EarsIPC`,
// and `EarsCoreTestSupport` depends only on `EarsCore` — it cannot import
// `EarsIPC` without a `Package.swift` change that is out of scope here. If a
// later task needs to share a fake transport, promoting these is a one-line
// dependency edit at that point.

/// A `SocketConnection` backed by in-memory streams. The test drives inbound
/// bytes via ``feed(_:)``/``feedLine(_:)`` and observes what the server wrote
/// via ``outbound``. ``stall`` makes ``send(_:)`` block — the hook the
/// bounded-queue drop test uses to simulate a client that never drains.
actor FakeSocketConnection: SocketConnection {
  nonisolated let inbound: AsyncStream<[UInt8]>
  private nonisolated let inboundContinuation: AsyncStream<[UInt8]>.Continuation

  /// Bytes the peer (server/client) wrote, in order.
  nonisolated let outbound: AsyncStream<[UInt8]>
  private nonisolated let outboundContinuation: AsyncStream<[UInt8]>.Continuation

  private var stalled: Bool
  private var closed = false
  private var stallWaiters: [CheckedContinuation<Void, Never>] = []

  init(stalled: Bool = false) {
    (inbound, inboundContinuation) = AsyncStream.makeStream()
    (outbound, outboundContinuation) = AsyncStream.makeStream()
    self.stalled = stalled
  }

  nonisolated func feed(_ bytes: [UInt8]) { inboundContinuation.yield(bytes) }

  nonisolated func feedLine<Value: Encodable>(_ value: Value) {
    guard let line = try? LineFramer.encodeLine(value) else { return }
    inboundContinuation.yield(line)
  }

  /// Signal end-of-input from the peer (client hung up).
  nonisolated func finishInbound() { inboundContinuation.finish() }

  func send(_ bytes: [UInt8]) async throws {
    while stalled && !closed {
      await withCheckedContinuation { stallWaiters.append($0) }
    }
    if closed { throw FakeConnectionError.closed }
    outboundContinuation.yield(bytes)
  }

  func close() async {
    closed = true
    releaseStallWaiters()
    outboundContinuation.finish()
    inboundContinuation.finish()
  }

  /// Let previously-stalled and future sends proceed.
  func unstall() {
    stalled = false
    releaseStallWaiters()
  }

  /// Make future sends block — for backpressure tests that need a connection
  /// that upgrades/handshakes normally first and only then stops draining.
  func stall() {
    stalled = true
  }

  private func releaseStallWaiters() {
    let waiters = stallWaiters
    stallWaiters = []
    for waiter in waiters { waiter.resume() }
  }
}

enum FakeConnectionError: Error { case closed }

/// A `SocketListener` the test feeds accepted connections into via
/// ``accept(_:)``. ``close()`` finishes the connection stream, which is how a
/// server's `run()` loop is made to return in a test.
actor FakeSocketListener: SocketListener {
  nonisolated let connections: AsyncStream<any SocketConnection>
  private nonisolated let continuation: AsyncStream<any SocketConnection>.Continuation

  init() {
    (connections, continuation) = AsyncStream.makeStream()
  }

  nonisolated func accept(_ connection: any SocketConnection) {
    continuation.yield(connection)
  }

  func close() async { continuation.finish() }
}

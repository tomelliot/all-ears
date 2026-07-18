import EarsCore
import Foundation

/// The control-socket client: connects to a daemon's Unix domain socket, sends
/// one ``ControlRequest`` at a time and awaits its typed ``ControlResponse``,
/// or subscribes and yields decoded ``EarsEvent``s.
///
/// ## One outstanding request per connection
///
/// The wire protocol has no request-id/correlation field — neither
/// ``ControlRequest`` nor ``ControlResponse`` carries one, and the spec's
/// examples are strictly one request then its one response. A client therefore
/// cannot match responses to requests if it pipelines several; the only sound
/// rule is to send one request and await its response before sending the next.
///
/// That rule is the intended calling convention (a real caller like the
/// `ears` CLI issues one command, awaits it, then issues the next), but it is
/// also enforced defensively inside ``send(_:expecting:)`` via an internal
/// FIFO lock (see ``withRequestLock(_:)``), rather than left to Swift actor
/// isolation. Actor methods are *reentrant* at `await` suspension points, so
/// two overlapping `send` calls are not automatically serialized by actor
/// isolation alone — without the explicit lock, a second call's wait for a
/// reply can silently displace the first's, leaking its continuation and
/// hanging that call forever. The lock makes concurrent misuse merely queue
/// (safe, if not the documented usage pattern) instead of deadlocking.
///
/// ``subscribe(_:)`` is terminal (see ``ControlSocketServer``): after it the
/// connection is an event stream. Calling ``send(_:expecting:)`` afterward — or
/// calling ``subscribe(_:)`` a second time — throws a clear
/// ``SocketTransportError`` rather than risking the same kind of hang: it
/// waits for any request already in flight to finish, then permanently claims
/// the read side, so a subsequent misuse fails fast instead of deadlocking.
public actor ControlSocketClient {
  private let connection: any SocketConnection
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  private var framer = LineFramer()
  private var lineBuffer: [[UInt8]] = []
  private var lineWaiter: CheckedContinuation<[UInt8]?, Never>?
  private var readerFinished = false
  private var subscribed = false

  /// Whether a `send`/`subscribe` critical section currently holds the request
  /// lock, and the FIFO of callers waiting to acquire it next. See
  /// ``withRequestLock(_:)``.
  private var requestLockHeld = false
  private var requestLockWaiters: [CheckedContinuation<Void, Never>] = []

  /// Wrap an established connection (used with a fake transport in tests, and
  /// by ``connect(toPath:)`` for the real one).
  public init(connection: any SocketConnection) {
    self.connection = connection
    Task { await self.runReadLoop() }
  }

  /// Connect to a daemon listening at `path`. Throws ``SocketTransportError``
  /// promptly if nothing is listening there.
  public static func connect(toPath path: String) async throws -> ControlSocketClient {
    let connection = try await NetworkSocketConnection.connect(toPath: path)
    return ControlSocketClient(connection: connection)
  }

  /// Send one request and await its typed response. Concurrent calls on the
  /// same client queue in FIFO order (see the type's doc comment) rather than
  /// racing on the wire or deadlocking. Throws if ``subscribe(_:)`` has
  /// already transitioned this connection to event-stream mode.
  public func send<Payload>(
    _ request: ControlRequest, expecting: Payload.Type
  ) async throws -> ControlResponse<Payload> {
    try requireNotSubscribed()
    return try await withRequestLock {
      try requireNotSubscribed()
      try await connection.send(LineFramer.encodeLine(request, using: encoder))
      guard let line = await nextLine() else {
        throw SocketTransportError.connectionFailed(
          "connection closed before a response arrived")
      }
      return try decoder.decode(ControlResponse<Payload>.self, from: Data(line))
    }
  }

  private func requireNotSubscribed() throws {
    guard !subscribed else {
      throw SocketTransportError.connectionFailed(
        "send(_:expecting:) called after subscribe(_:) put this connection in event-stream mode")
    }
  }

  /// Runs `body` as a critical section admitting only one caller at a time,
  /// queueing others in FIFO arrival order. This is what makes ``send(_:expecting:)``
  /// safe under concurrent calls: without it, two callers could both reach
  /// the inbound-line wait before either's response arrives, and the second's
  /// wait would silently replace the first's, orphaning it forever (a real
  /// hang this type shipped with once, before this lock was added).
  private func withRequestLock<T>(_ body: () async throws -> T) async rethrows -> T {
    await acquireRequestLock()
    defer { releaseRequestLock() }
    return try await body()
  }

  private func acquireRequestLock() async {
    if requestLockHeld {
      await withCheckedContinuation { requestLockWaiters.append($0) }
    } else {
      requestLockHeld = true
    }
  }

  private func releaseRequestLock() {
    if !requestLockWaiters.isEmpty {
      requestLockWaiters.removeFirst().resume()  // ownership passes; stays held
    } else {
      requestLockHeld = false
    }
  }

  /// Switch this connection into event-stream mode and yield decoded events
  /// until the connection closes. Terminal: waits for any ``send(_:expecting:)``
  /// already in flight to finish, then permanently claims the read side, so a
  /// `send` (or a second `subscribe`) issued after this returns fails fast via
  /// ``requireNotSubscribed()`` instead of racing or hanging. Cancelling the
  /// returned stream stops decoding but does not itself close the connection —
  /// call ``close()`` for that.
  public func subscribe(_ request: SubscribeRequest) async throws -> AsyncStream<EarsEvent> {
    try requireNotSubscribed()
    await acquireRequestLock()  // wait for any in-flight send; deliberately never released
    subscribed = true
    try await connection.send(LineFramer.encodeLine(request, using: encoder))
    return AsyncStream { continuation in
      let task = Task {
        while let line = await self.nextLine() {
          if let event = try? JSONDecoder().decode(EarsEvent.self, from: Data(line)) {
            continuation.yield(event)
          }
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// Close the underlying connection.
  public func close() async {
    await connection.close()
  }

  // MARK: - Inbound line handoff

  private func runReadLoop() async {
    for await chunk in connection.inbound {
      let lines = framer.append(chunk)
      if !lines.isEmpty { deliver(lines) }
    }
    readerFinished = true
    wakeWaiter()
  }

  private func deliver(_ lines: [[UInt8]]) {
    lineBuffer.append(contentsOf: lines)
    wakeWaiter()
  }

  /// The next complete inbound line, or `nil` once the connection has closed
  /// and no buffered lines remain. At most one waiter exists at a time: the
  /// request lock serializes `send` callers, and `subscribe` only starts
  /// pulling lines after acquiring (and never releasing) that same lock.
  private func nextLine() async -> [UInt8]? {
    if !lineBuffer.isEmpty { return lineBuffer.removeFirst() }
    if readerFinished { return nil }
    return await withCheckedContinuation { continuation in
      lineWaiter = continuation
    }
  }

  private func wakeWaiter() {
    guard let waiter = lineWaiter else { return }
    if !lineBuffer.isEmpty {
      lineWaiter = nil
      waiter.resume(returning: lineBuffer.removeFirst())
    } else if readerFinished {
      lineWaiter = nil
      waiter.resume(returning: nil)
    }
  }
}

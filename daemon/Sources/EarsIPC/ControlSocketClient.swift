import EarsCore
import Foundation

/// The v2 control client: connects to a daemon's Unix domain socket, performs
/// the `hello` handshake, sends id-correlated requests, and (optionally)
/// subscribes to the live feed — all over one connection, because with
/// correlation ids a subscribed connection may keep issuing requests.
///
/// ## Correlation
///
/// Every request gets a fresh integer id and a pending continuation keyed by
/// it; a single reader loop routes each inbound line by shape — `id` present
/// ⇒ a response resolved against the pending map, `event` present ⇒ a
/// notification yielded to the subscription stream. Out-of-order completion
/// is therefore fine by construction; a disconnect fails every pending
/// request instead of stranding them.
public actor ControlSocketClient {
  private let connection: any SocketConnection
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  private var framer = LineFramer()
  private var nextID: Int64 = 0
  private var pending: [RequestID: CheckedContinuation<Data, any Error>] = [:]
  private var eventContinuation: AsyncStream<EventFrame>.Continuation?
  private var readerFinished = false

  /// Wrap an established connection (a fake transport in tests,
  /// ``connect(toPath:)``'s real one otherwise).
  public init(connection: any SocketConnection) {
    self.connection = connection
    Task { await self.runReadLoop() }
  }

  /// Connect to a daemon listening at `path`. Throws ``SocketTransportError``
  /// promptly if nothing is listening there. The caller still must
  /// ``hello(client:)`` before anything else — the daemon requires it.
  public static func connect(toPath path: String) async throws -> ControlSocketClient {
    let connection = try await NetworkSocketConnection.connect(toPath: path)
    return ControlSocketClient(connection: connection)
  }

  /// The mandatory first request on every connection.
  @discardableResult
  public func hello(client: String) async throws -> HelloResult {
    let id = allocateID()
    let frame = ControlRequestFrame.hello(id: id, params: HelloParams(client: client))
    let data = try await roundTrip(frame, id: id)
    return try decoder.decode(ControlResponseFrame<HelloResult>.self, from: data).get()
  }

  /// Send one call and await its typed result, throwing the response's
  /// ``WireError`` on an error frame.
  public func send<Payload: Codable & Sendable & Hashable>(
    _ call: ControlCall, expecting: Payload.Type
  ) async throws -> Payload {
    let id = allocateID()
    let data = try await roundTrip(.call(id: id, call: call), id: id)
    return try decoder.decode(ControlResponseFrame<Payload>.self, from: data).get()
  }

  /// Subscribe: returns the state snapshot and the notification stream.
  /// The stream finishes when the connection closes; cancelling it stops
  /// decoding but does not itself close the connection — call ``close()``.
  public func subscribe(
    _ params: SubscribeParams = SubscribeParams()
  ) async throws -> (snapshot: SnapshotData, events: AsyncStream<EventFrame>) {
    // The stream exists before the request goes out, so an event delivered
    // between the daemon registering the subscription and the snapshot
    // response arriving is buffered, not lost.
    let (stream, continuation) = AsyncStream.makeStream(
      of: EventFrame.self, bufferingPolicy: .unbounded)
    eventContinuation = continuation
    let snapshot = try await send(.subscribe(params), expecting: SnapshotData.self)
    return (snapshot, stream)
  }

  /// Close the underlying connection.
  public func close() async {
    await connection.close()
  }

  // MARK: - Internals

  private func allocateID() -> RequestID {
    nextID += 1
    return .int(nextID)
  }

  private func roundTrip(_ frame: ControlRequestFrame, id: RequestID) async throws -> Data {
    guard !readerFinished else {
      throw SocketTransportError.connectionFailed("connection is closed")
    }
    let line = try LineFramer.encodeLine(frame, using: encoder)
    return try await withCheckedThrowingContinuation { continuation in
      pending[id] = continuation
      Task {
        do {
          try await self.connection.send(line)
        } catch {
          self.fail(id: id, with: error)
        }
      }
    }
  }

  private func fail(id: RequestID, with error: any Error) {
    pending.removeValue(forKey: id)?.resume(throwing: error)
  }

  private func runReadLoop() async {
    for await chunk in connection.inbound {
      for line in framer.append(chunk) {
        route(Data(line))
      }
    }
    readerFinished = true
    let stranded = pending
    pending = [:]
    for (_, continuation) in stranded {
      continuation.resume(
        throwing: SocketTransportError.connectionFailed(
          "connection closed before a response arrived"))
    }
    eventContinuation?.finish()
    eventContinuation = nil
  }

  /// Routes one inbound line by shape: `id` ⇒ response, `event` ⇒
  /// notification. Unroutable lines are dropped (nothing useful to do with
  /// them client-side).
  private func route(_ data: Data) {
    struct Peek: Decodable {
      var id: RequestID?
      var event: EventKind?
    }
    guard let peek = try? decoder.decode(Peek.self, from: data) else { return }
    if let id = peek.id, let continuation = pending.removeValue(forKey: id) {
      continuation.resume(returning: data)
      return
    }
    if peek.event != nil, let frame = try? decoder.decode(EventFrame.self, from: data) {
      eventContinuation?.yield(frame)
    }
  }
}

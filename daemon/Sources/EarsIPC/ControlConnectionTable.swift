import EarsCore
import Foundation

/// The transport-agnostic core of a control-plane server's per-connection
/// state: bounded outbound queues with drop-oldest backpressure, the
/// "subscribe is terminal" subscription state, and `EventFilter`-matched
/// pub/sub fan-out — everything ``ControlSocketServer`` (NDJSON over the Unix
/// socket) and ``ControlWebSocketServer`` (JSON text frames over the loopback
/// WebSocket) share, factored out so a backpressure or event-filter change
/// never needs two hand-synced implementations.
///
/// Parameterized per connection only by "how does one encoded JSON payload
/// become wire bytes" (`encodeWire`: append `\n` for NDJSON, wrap in an RFC
/// 6455 text frame for WebSocket) and "how do bytes reach the peer" (`send`).
///
/// Not an actor: each server actor owns one instance inside its own
/// isolation, and every method here is synchronous — the async parts
/// (awaiting the request handler, reading the transport) stay in the owning
/// actor, so no `inout` state ever spans a suspension point.
struct ControlConnectionTable {
  struct Connection {
    let outbound: AsyncStream<[UInt8]>.Continuation
    let writer: Task<Void, Never>
    let encodeWire: @Sendable (Data) -> [UInt8]
    var subscription: SubscribeRequest?
  }

  private var connections: [Int: Connection] = [:]
  private var nextConnectionID = 0
  /// Total payloads dropped across all connections because their outbound
  /// queue was full (the backpressure counter, surfaced for tests and
  /// diagnostics).
  private(set) var dropped = 0

  private let queueBound: Int
  /// Names the owning transport in drop logs, e.g. `"control socket"`.
  private let label: String
  private let log: @Sendable (String) -> Void

  init(queueBound: Int, label: String, log: @escaping @Sendable (String) -> Void) {
    self.queueBound = queueBound
    self.label = label
    self.log = log
  }

  var count: Int { connections.count }

  var subscriberCount: Int {
    connections.values.filter { $0.subscription != nil }.count
  }

  /// Registers a new connection: allocates its id, its bounded outbound
  /// queue, and the dedicated writer task that drains the queue via `send`.
  mutating func register(
    send: @escaping @Sendable ([UInt8]) async throws -> Void,
    encodeWire: @escaping @Sendable (Data) -> [UInt8]
  ) -> Int {
    let id = nextConnectionID
    nextConnectionID += 1
    let (stream, continuation) = AsyncStream.makeStream(
      of: [UInt8].self, bufferingPolicy: .bufferingNewest(queueBound))
    let writer = Task.detached {
      for await line in stream {
        try? await send(line)
      }
    }
    connections[id] = Connection(
      outbound: continuation, writer: writer, encodeWire: encodeWire, subscription: nil)
    return id
  }

  func isSubscribed(_ id: Int) -> Bool {
    connections[id]?.subscription != nil
  }

  /// Transitions `id` into event-stream mode ("subscribe is terminal").
  mutating func setSubscription(_ subscription: SubscribeRequest, for id: Int) {
    connections[id]?.subscription = subscription
  }

  /// Fan `event` out to every subscribed connection whose filter matches,
  /// encoding the JSON once (wire framing is still per connection). Dropped
  /// deliveries (full queue) are counted and logged.
  mutating func publish(_ event: EarsEvent, using encoder: JSONEncoder) {
    var encoded: Data?
    for (id, connection) in connections {
      guard let subscription = connection.subscription,
        EventFilter.matches(event, subscription)
      else { continue }
      if encoded == nil { encoded = try? encoder.encode(event) }
      guard let payload = encoded else { return }
      deliver(payload, to: id, what: "event")
    }
  }

  /// Queues one control reply for `id`.
  mutating func enqueue(_ reply: ControlReply, to id: Int, using encoder: JSONEncoder) {
    guard let payload = try? reply.encoded(using: encoder) else { return }
    deliver(payload, to: id, what: "reply")
  }

  private mutating func deliver(_ payload: Data, to id: Int, what: String) {
    guard let connection = connections[id] else { return }
    if case .dropped = connection.outbound.yield(connection.encodeWire(payload)) {
      dropped += 1
      log("\(label): dropped \(what) on connection \(id) (outbound queue full)")
    }
  }

  /// Removes one connection, cancelling its writer and finishing its queue.
  /// Returns whether it was present (the caller closes the transport).
  @discardableResult
  mutating func remove(_ id: Int) -> Bool {
    guard let connection = connections.removeValue(forKey: id) else { return false }
    connection.writer.cancel()
    connection.outbound.finish()
    return true
  }

  /// Removes every connection (server shutdown); the caller closes the
  /// transports it tracked alongside.
  mutating func removeAll() {
    for (_, connection) in connections {
      connection.writer.cancel()
      connection.outbound.finish()
    }
    connections = [:]
  }
}

/// Minimal decode to read only the `cmd` discriminator, distinguishing a
/// `subscribe` (which becomes a ``SubscribeRequest``) from the
/// ``ControlRequest`` commands without committing to either decode first —
/// shared by both control-plane transports.
enum ControlCommandPeek {
  private struct Peek: Decodable {
    let cmd: String
  }

  static func isSubscribe(_ data: Data, using decoder: JSONDecoder) -> Bool {
    (try? decoder.decode(Peek.self, from: data))?.cmd == "subscribe"
  }
}

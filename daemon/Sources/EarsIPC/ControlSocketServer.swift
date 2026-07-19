import EarsCore
import Foundation

/// The control-socket server: accepts connections on a ``SocketListener``,
/// frames newline-delimited JSON per connection, dispatches each
/// ``ControlRequest`` to a caller-supplied handler, and fans published
/// ``EarsEvent``s out to subscribed connections — all under a bounded,
/// drop-on-overflow outbound queue per connection.
///
/// This is the transport a future `ControlServer` actor plugs its command
/// dispatch into: it owns framing, connection lifecycle, pub/sub fan-out, and
/// backpressure, and knows nothing about what any command *means*. The handler
/// is `(ControlRequest) async -> ControlReply` — the seam where business logic
/// attaches. See ``ControlReply`` for why the reply is type-erased.
///
/// The per-connection subscribe/queue/backpressure/fan-out state lives in the
/// shared ``ControlConnectionTable`` — the same core
/// ``ControlWebSocketServer`` runs on — so this actor is just the NDJSON
/// transport adapter: accept, line-frame, dispatch, close.
///
/// ## Subscribe is terminal for a connection
///
/// A connection is request/response until it sends a `subscribe`; from then it
/// is an event stream until it closes. Further inbound lines on a subscribed
/// connection are ignored. The spec presents `subscribe` as a mode the
/// connection *becomes* ("either request/response or, after `subscribe`, an
/// event stream") with no example of mixing the two and no request-id field to
/// correlate interleaved replies against a live event stream — so the simpler,
/// unambiguous "subscribe is terminal" reading is chosen. A client that wants
/// both opens a second connection.
///
/// ## Backpressure: bounded queue, drop-and-log
///
/// Each connection's outbound direction — both control replies and published
/// events — passes through one bounded FIFO (`bufferingNewest`, default
/// ``defaultOutboundQueueBound`` = 128 lines). A dedicated writer task drains
/// it to the socket; when a slow or stalled client stops draining, the writer
/// blocks on the socket write, the queue fills, and further lines are dropped
/// (oldest-first, keeping the freshest events) with the drop counted in
/// ``droppedLineCount`` and logged — never blocking the whole server or growing
/// without bound, matching the RAM ring's drop-loud policy and the architecture
/// doc's backpressure requirement. 128 sits mid-range of the 64–256 guidance:
/// large enough to ride out a brief consumer stall, small enough that a truly
/// dead client is capped at a few KB of retained lines.
public actor ControlSocketServer {
  /// The seam a future `ControlServer` plugs command dispatch into.
  public typealias Handler = @Sendable (ControlRequest) async -> ControlReply

  /// Default per-connection outbound queue depth. See the type's backpressure note.
  public static let defaultOutboundQueueBound = 128

  private let listener: any SocketListener
  private let handler: Handler
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  private var table: ControlConnectionTable
  private var sockets: [Int: any SocketConnection] = [:]

  public init(
    listener: any SocketListener,
    outboundQueueBound: Int = ControlSocketServer.defaultOutboundQueueBound,
    log: @escaping @Sendable (String) -> Void = { _ in },
    handler: @escaping Handler
  ) {
    self.listener = listener
    self.handler = handler
    self.table = ControlConnectionTable(
      queueBound: outboundQueueBound, label: "control socket", log: log)
  }

  /// Total lines dropped across all connections because their outbound queue
  /// was full (the backpressure counter, surfaced for tests and diagnostics).
  public var droppedLineCount: Int { table.dropped }

  /// Number of currently-open connections.
  public var connectionCount: Int { table.count }

  /// Number of open connections currently in event-stream (subscribed) mode.
  public var subscriberCount: Int { table.subscriberCount }

  /// Accept connections until the listener closes. Returns when
  /// ``shutdown()`` (or the listener itself) finishes the connection stream.
  public func run() async {
    for await socket in listener.connections {
      accept(socket)
    }
  }

  /// Fan `event` out to every subscribed connection whose filter matches,
  /// encoding it once. Dropped deliveries (full queue) are counted and logged.
  public func publish(_ event: EarsEvent) {
    table.publish(event, using: encoder)
  }

  /// Stop listening and close every open connection.
  public func shutdown() async {
    await listener.close()
    table.removeAll()
    let open = sockets
    sockets = [:]
    for (_, socket) in open {
      await socket.close()
    }
  }

  private func accept(_ socket: any SocketConnection) {
    let id = table.register(
      send: { bytes in try await socket.send(bytes) },
      encodeWire: { data in Array(data) + [0x0A] })
    sockets[id] = socket
    Task { await self.readLoop(id: id, socket: socket) }
  }

  private func readLoop(id: Int, socket: any SocketConnection) async {
    var framer = LineFramer()
    var subscribed = false
    for await chunk in socket.inbound {
      for line in framer.append(chunk) {
        if subscribed { continue }  // terminal: ignore further input once subscribed
        if await handle(line: line, id: id) { subscribed = true }
      }
    }
    await teardown(id: id)
  }

  /// Process one framed request line. Returns `true` when it was a `subscribe`
  /// that transitioned the connection into event-stream mode. The handler is
  /// awaited inline so replies stay in request order; the actor is released
  /// during the await, so `publish` and other connections still interleave.
  private func handle(line: [UInt8], id: Int) async -> Bool {
    let data = Data(line)
    if ControlCommandPeek.isSubscribe(data, using: decoder) {
      if let subscription = try? decoder.decode(SubscribeRequest.self, from: data) {
        table.setSubscription(subscription, for: id)
        return true
      }
      table.enqueue(.failure("malformed subscribe request"), to: id, using: encoder)
      return false
    }
    if let request = try? decoder.decode(ControlRequest.self, from: data) {
      let reply = await handler(request)
      table.enqueue(reply, to: id, using: encoder)
      return false
    }
    table.enqueue(.failure("unrecognised request"), to: id, using: encoder)
    return false
  }

  private func teardown(id: Int) async {
    guard table.remove(id) else { return }
    if let socket = sockets.removeValue(forKey: id) {
      await socket.close()
    }
  }
}

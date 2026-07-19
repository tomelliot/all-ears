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
  private let queueBound: Int
  private let log: @Sendable (String) -> Void
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  private var connections: [Int: Connection] = [:]
  private var nextConnectionID = 0
  private var dropped = 0

  private struct Connection {
    let socket: any SocketConnection
    let outbound: AsyncStream<[UInt8]>.Continuation
    let writer: Task<Void, Never>
    var subscription: SubscribeRequest?
  }

  public init(
    listener: any SocketListener,
    outboundQueueBound: Int = ControlSocketServer.defaultOutboundQueueBound,
    log: @escaping @Sendable (String) -> Void = { _ in },
    handler: @escaping Handler
  ) {
    self.listener = listener
    self.queueBound = outboundQueueBound
    self.log = log
    self.handler = handler
  }

  /// Total lines dropped across all connections because their outbound queue
  /// was full (the backpressure counter, surfaced for tests and diagnostics).
  public var droppedLineCount: Int { dropped }

  /// Number of currently-open connections.
  public var connectionCount: Int { connections.count }

  /// Number of open connections currently in event-stream (subscribed) mode.
  public var subscriberCount: Int {
    connections.values.filter { $0.subscription != nil }.count
  }

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
    var encoded: [UInt8]?
    for (id, connection) in connections {
      guard let subscription = connection.subscription,
        EventFilter.matches(event, subscription)
      else { continue }
      if encoded == nil { encoded = try? LineFramer.encodeLine(event, using: encoder) }
      guard let line = encoded else { return }
      deliver(line, to: id, connection: connection, what: "event")
    }
  }

  /// Stop listening and close every open connection.
  public func shutdown() async {
    await listener.close()
    let open = connections
    connections = [:]
    for (_, connection) in open {
      connection.writer.cancel()
      connection.outbound.finish()
      await connection.socket.close()
    }
  }

  private func accept(_ socket: any SocketConnection) {
    let id = nextConnectionID
    nextConnectionID += 1

    let (stream, continuation) = AsyncStream.makeStream(
      of: [UInt8].self, bufferingPolicy: .bufferingNewest(queueBound))
    let writer = Task.detached {
      for await line in stream {
        try? await socket.send(line)
      }
    }
    connections[id] = Connection(
      socket: socket, outbound: continuation, writer: writer, subscription: nil)

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
    if isSubscribe(data) {
      if let subscription = try? decoder.decode(SubscribeRequest.self, from: data) {
        connections[id]?.subscription = subscription
        return true
      }
      enqueue(.failure("malformed subscribe request"), to: id)
      return false
    }
    if let request = try? decoder.decode(ControlRequest.self, from: data) {
      enqueue(await handler(request), to: id)
      return false
    }
    enqueue(.failure("unrecognised request"), to: id)
    return false
  }

  private func isSubscribe(_ data: Data) -> Bool {
    (try? decoder.decode(CommandPeek.self, from: data))?.cmd == "subscribe"
  }

  private func enqueue(_ reply: ControlReply, to id: Int) {
    guard let connection = connections[id],
      let data = try? reply.encoded(using: encoder)
    else { return }
    var line = data
    line.append(0x0A)
    deliver(Array(line), to: id, connection: connection, what: "reply")
  }

  private func deliver(
    _ line: [UInt8], to id: Int, connection: Connection, what: String
  ) {
    if case .dropped = connection.outbound.yield(line) {
      dropped += 1
      log("control socket: dropped \(what) on connection \(id) (outbound queue full)")
    }
  }

  private func teardown(id: Int) async {
    guard let connection = connections.removeValue(forKey: id) else { return }
    connection.writer.cancel()
    connection.outbound.finish()
    await connection.socket.close()
  }

  /// Minimal decode to read only the `cmd` discriminator, distinguishing a
  /// `subscribe` (which becomes a ``SubscribeRequest``) from the
  /// ``ControlRequest`` commands without committing to either decode first.
  private struct CommandPeek: Decodable {
    let cmd: String
  }
}

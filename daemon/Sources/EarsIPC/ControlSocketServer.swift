import EarsCore
import Foundation

/// The seam command dispatch plugs into: one decoded, capability-checked
/// ``ControlCall`` in, one type-erased reply out. Shared by both control
/// transports (`ControlServer.makeHandler()` supplies the closure for both,
/// so dispatch is never duplicated across transports).
public typealias ControlHandler = @Sendable (ControlCall) async -> ControlReply

/// The v2 control server on the Unix domain socket: accepts connections,
/// frames newline-delimited JSON, runs the shared per-connection protocol
/// state machine (`hello` gating, capability enforcement — this transport
/// carries the full ``Capability/all`` tier), dispatches calls to the
/// injected handler, and fans revision-tagged ``EventFrame``s out to
/// subscribed connections — all under a bounded, drop-on-overflow outbound
/// queue per connection.
///
/// ## Correlation, not FIFO
///
/// Every request carries a client-chosen `id` echoed on its response, so
/// requests are dispatched as they arrive and replies may complete out of
/// order; nothing here maintains request order. Subscribing is **not**
/// terminal: a subscribed connection keeps issuing requests — one connection
/// per frontend suffices.
///
/// ## Backpressure: bounded queue, drop-and-log
///
/// Unchanged from v1: each connection's outbound direction passes through
/// one bounded FIFO (default ``defaultOutboundQueueBound`` = 128 payloads),
/// drained by a dedicated writer task; a stalled client's lines are dropped
/// oldest-first, counted in ``droppedLineCount`` and logged. A dropped state
/// event surfaces to that client as a `rev` gap, whose documented recovery
/// is resubscribe-for-snapshot.
public actor ControlSocketServer {
  /// Default per-connection outbound queue depth. See the type's backpressure note.
  public static let defaultOutboundQueueBound = 128

  private let listener: any SocketListener
  private let identity: ControlServerIdentity
  private let handler: ControlHandler
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  private var table: ControlConnectionTable
  private var sockets: [Int: any SocketConnection] = [:]

  public init(
    listener: any SocketListener,
    identity: ControlServerIdentity,
    outboundQueueBound: Int = ControlSocketServer.defaultOutboundQueueBound,
    log: @escaping @Sendable (String) -> Void = { _ in },
    handler: @escaping ControlHandler
  ) {
    self.listener = listener
    self.identity = identity
    self.handler = handler
    self.table = ControlConnectionTable(
      queueBound: outboundQueueBound, label: "control socket", log: log)
  }

  /// Total lines dropped across all connections because their outbound queue
  /// was full (the backpressure counter, surfaced for tests and diagnostics).
  public var droppedLineCount: Int { table.dropped }

  /// Number of currently-open connections.
  public var connectionCount: Int { table.count }

  /// Number of open connections with a registered subscription.
  public var subscriberCount: Int { table.subscriberCount }

  /// Accept connections until the listener closes. Returns when
  /// ``shutdown()`` (or the listener itself) finishes the connection stream.
  public func run() async {
    for await socket in listener.connections {
      accept(socket)
    }
  }

  /// Fan `frame` out to every subscribed connection whose filter matches.
  public func publish(_ frame: EventFrame) {
    table.publish(frame, using: encoder)
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
    for await chunk in socket.inbound {
      for line in framer.append(chunk) {
        await handle(Data(line), connection: id)
      }
    }
    await teardown(id: id)
  }

  /// Applies the shared protocol state machine's decision for one payload.
  /// The handler is awaited inline per line; correlation ids make ordering a
  /// client concern, and the actor is released during the await so `publish`
  /// and other connections still interleave.
  private func handle(_ data: Data, connection id: Int) async {
    switch ControlFrameProcessor.decide(
      data, helloDone: table.helloDone(id), capabilities: Capability.all, decoder: decoder)
    {
    case .respond(let requestID, let reply):
      table.respond(reply, id: requestID, to: id, using: encoder)
    case .completeHello(let requestID):
      table.markHello(id)
      table.respond(
        ControlFrameProcessor.helloReply(identity: identity, capabilities: Capability.all),
        id: requestID, to: id, using: encoder)
    case .subscribe(let requestID, let params):
      // Register the filter BEFORE taking the snapshot: an event racing the
      // snapshot is then delivered (possibly stale relative to the snapshot,
      // which the client's rev rule ignores) rather than silently missed.
      table.setSubscription(params, for: id)
      let reply = await handler(.subscribe(params))
      table.respond(reply, id: requestID, to: id, using: encoder)
    case .dispatch(let requestID, let call):
      let reply = await handler(call)
      table.respond(reply, id: requestID, to: id, using: encoder)
    }
  }

  private func teardown(id: Int) async {
    guard table.remove(id) else { return }
    if let socket = sockets.removeValue(forKey: id) {
      await socket.close()
    }
  }
}

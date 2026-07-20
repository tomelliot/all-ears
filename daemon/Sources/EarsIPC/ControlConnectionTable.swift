import EarsCore
import Foundation

/// The transport-agnostic core of a v2 control server's per-connection
/// state: bounded outbound queues with drop-oldest backpressure, the
/// `hello`-handshake and subscription state, and event fan-out — everything
/// ``ControlSocketServer`` (NDJSON over the Unix socket) and
/// ``ControlWebSocketServer`` (JSON text frames over the loopback WebSocket)
/// share, factored out so a backpressure or filter change never needs two
/// hand-synced implementations.
///
/// Parameterized per connection only by "how does one encoded JSON payload
/// become wire bytes" (`encodeWire`) and "how do bytes reach the peer"
/// (`send`). The *capability tier* is fixed per table (one table per
/// transport, and privilege differs by transport, not by dialect).
///
/// Not an actor: each server actor owns one instance inside its own
/// isolation, and every method here is synchronous — the async parts
/// (awaiting the request handler, reading the transport) stay in the owning
/// actor.
struct ControlConnectionTable {
  struct Connection {
    let outbound: AsyncStream<[UInt8]>.Continuation
    let writer: Task<Void, Never>
    let encodeWire: @Sendable (Data) -> [UInt8]
    var helloDone = false
    var subscription: SubscribeParams?
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
      outbound: continuation, writer: writer, encodeWire: encodeWire)
    return id
  }

  func helloDone(_ id: Int) -> Bool {
    connections[id]?.helloDone ?? false
  }

  /// Marks the handshake complete — every later request on this connection
  /// skips the `hello_required` gate.
  mutating func markHello(_ id: Int) {
    connections[id]?.helloDone = true
  }

  /// Registers (or replaces) this connection's subscription. Unlike v1,
  /// subscribing is not terminal — the connection keeps serving requests.
  mutating func setSubscription(_ subscription: SubscribeParams, for id: Int) {
    connections[id]?.subscription = subscription
  }

  /// Fan `frame` out to every subscribed connection whose filter matches,
  /// encoding the JSON once (wire framing is still per connection). State
  /// frames are always delivered to every subscriber — unconditional
  /// delivery is what keeps `rev` contiguous; telemetry frames pass through
  /// the subscription's kind/source filter. Dropped deliveries (full queue)
  /// are counted and logged.
  mutating func publish(_ frame: EventFrame, using encoder: JSONEncoder) {
    var encoded: Data?
    for (id, connection) in connections {
      guard let subscription = connection.subscription,
        EventFilter.matches(frame, subscription)
      else { continue }
      if encoded == nil { encoded = try? encoder.encode(frame) }
      guard let payload = encoded else { return }
      deliver(payload, to: id, what: "event")
    }
  }

  /// Queues one reply frame for `id`'s request on connection `connectionID`.
  mutating func respond(
    _ reply: ControlReply, id: RequestID, to connectionID: Int, using encoder: JSONEncoder
  ) {
    guard let payload = try? reply.encoded(id: id, using: encoder) else { return }
    deliver(payload, to: connectionID, what: "reply")
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

/// The daemon identity a `hello` result advertises — one value shared by
/// both control transports.
public struct ControlServerIdentity: Sendable {
  /// e.g. `earsd 0.9.0`.
  public var daemon: String
  /// Fresh per daemon start; revision counters are scoped to it.
  public var bootID: String

  public init(daemon: String, bootID: String) {
    self.daemon = daemon
    self.bootID = bootID
  }
}

/// What to do with one inbound control text payload — the transport-agnostic
/// protocol state machine (`hello` gating, capability enforcement, envelope
/// validation), factored out of both servers as a pure decision so it is
/// unit-testable with no sockets or actors. The owning server actor applies
/// the decision: mutate its table, call its handler, enqueue the reply.
enum ControlFrameDecision {
  /// Reply immediately (a protocol-level error, or the hello result).
  case respond(id: RequestID, ControlReply)
  /// A valid `hello`: mark the connection and reply with `helloResult`.
  case completeHello(id: RequestID)
  /// A valid `subscribe`: register the filter *first*, then dispatch the
  /// call to the handler for the snapshot result.
  case subscribe(id: RequestID, SubscribeParams)
  /// Any other valid call: dispatch to the handler.
  case dispatch(id: RequestID, ControlCall)
}

enum ControlFrameProcessor {
  /// Decides how to handle one inbound JSON payload given the connection's
  /// handshake state and its transport's capability tier.
  static func decide(
    _ data: Data,
    helloDone: Bool,
    capabilities: Set<Capability>,
    decoder: JSONDecoder
  ) -> ControlFrameDecision {
    let head = try? decoder.decode(ControlRequestHead.self, from: data)
    guard let rawMethod = head?.method, let id = head?.id else {
      return .respond(
        id: head?.id ?? .none,
        .failure(.invalidRequest, "malformed request envelope: expected {id, method, params?}"))
    }
    guard let method = ControlMethod(rawValue: rawMethod) else {
      return .respond(id: id, .failure(.unknownMethod, "unknown method '\(rawMethod)'"))
    }

    if method == .hello {
      guard let frame = try? decoder.decode(ControlRequestFrame.self, from: data),
        case .hello(_, let params) = frame
      else {
        return .respond(id: id, .failure(.invalidRequest, "malformed hello params"))
      }
      guard params.protocolVersion == ControlProtocolV2.version else {
        return .respond(
          id: id,
          .failure(
            .unsupportedProtocol,
            "this daemon speaks protocol \(ControlProtocolV2.version)"))
      }
      return .completeHello(id: id)
    }

    guard helloDone else {
      return .respond(
        id: id, .failure(.helloRequired, "hello must be the first request on a connection"))
    }
    guard let capability = method.capability, capabilities.contains(capability) else {
      return .respond(
        id: id,
        .failure(.notPermitted, "method '\(method.rawValue)' is not permitted on this transport"))
    }

    let call: ControlCall
    do {
      let frame = try decoder.decode(ControlRequestFrame.self, from: data)
      guard case .call(_, let decoded) = frame else {
        return .respond(id: id, .failure(.invalidRequest, "malformed request"))
      }
      call = decoded
    } catch {
      return .respond(
        id: id, .failure(.invalidRequest, "invalid params for '\(method.rawValue)': \(error)"))
    }

    if case .subscribe(let params) = call {
      return .subscribe(id: id, params)
    }
    return .dispatch(id: id, call)
  }

  /// The hello result for a connection on a transport with `capabilities`.
  static func helloReply(
    identity: ControlServerIdentity, capabilities: Set<Capability>
  ) -> ControlReply {
    ControlReply(
      result: HelloResult(
        daemon: identity.daemon,
        bootID: identity.bootID,
        capabilities: Capability.allCases.filter { capabilities.contains($0) }))
  }
}

import EarsCore
import Foundation

/// The loopback WebSocket control-plane endpoint
/// (`ws://127.0.0.1:<port>/control`, `[earsd.control_ws]`) — the browser
/// extension's route to the v2 control protocol, alongside (not replacing)
/// the privileged Unix socket. Identical frames on both transports;
/// **privilege differs by transport**: connections here get only
/// ``Capability/controlWebSocket`` (`observe` + `meetings`), so even an
/// allowed Origin cannot reach source/session/admin verbs.
///
/// Structured like ``IngestWebSocketServer`` — the same hand-rolled HTTP
/// upgrade (``HTTPHandshakeReader``) and RFC 6455 framing
/// (``WebSocketFrameReader``/``WebSocketFrameWriter``), with the fail-closed
/// Origin allowlist checked *before* the `101` response, and for the same
/// reason: `NWProtocolWebSocket` exposes no pre-accept hook for path/Origin
/// validation. Binary frames are rejected on the control plane (PCM belongs
/// to `/ingest` only).
///
/// Per-connection protocol state (`hello` gating, subscriptions,
/// backpressure) is the shared ``ControlConnectionTable``; command dispatch
/// is the same injected ``ControlHandler`` closure the Unix socket server is
/// constructed with.
public actor ControlWebSocketServer {
  /// Same default and rationale as
  /// ``ControlSocketServer/defaultOutboundQueueBound``.
  public static let defaultOutboundQueueBound = 128

  private let listener: any SocketListener
  private let allowedOrigins: Set<String>
  private let identity: ControlServerIdentity
  private let handler: ControlHandler
  private let log: @Sendable (String) -> Void
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  private var table: ControlConnectionTable
  private var sockets: [Int: any SocketConnection] = [:]
  private var connectionTasks: [Int: Task<Void, Never>] = [:]
  private var nextTaskID = 0

  /// - Parameters:
  ///   - allowedOrigins: `[earsd.control_ws].allowed_origins`. Empty rejects
  ///     every connection (fail closed) — this is not "allow all".
  public init(
    listener: any SocketListener,
    allowedOrigins: [String],
    identity: ControlServerIdentity,
    outboundQueueBound: Int = ControlWebSocketServer.defaultOutboundQueueBound,
    log: @escaping @Sendable (String) -> Void = { _ in },
    handler: @escaping ControlHandler
  ) {
    self.listener = listener
    self.allowedOrigins = Set(allowedOrigins)
    self.identity = identity
    self.handler = handler
    self.log = log
    self.table = ControlConnectionTable(
      queueBound: outboundQueueBound, label: "control ws", log: log)
  }

  /// Backpressure/introspection counters, mirroring ``ControlSocketServer``'s.
  public var droppedLineCount: Int { table.dropped }
  public var connectionCount: Int { table.count }
  public var subscriberCount: Int { table.subscriberCount }

  /// Accept connections until the listener closes.
  public func run() async {
    for await socket in listener.connections {
      accept(socket)
    }
  }

  /// Fan `frame` out to every subscribed connection whose filter matches —
  /// the WebSocket leg of the same live feed the Unix socket serves.
  public func publish(_ frame: EventFrame) {
    table.publish(frame, using: encoder)
  }

  /// Stop listening and tear down every open connection.
  public func shutdown() async {
    await listener.close()
    let tasks = connectionTasks
    connectionTasks = [:]
    for (_, task) in tasks { task.cancel() }
    table.removeAll()
    let open = sockets
    sockets = [:]
    for (_, socket) in open {
      await socket.close()
    }
  }

  private func accept(_ socket: any SocketConnection) {
    let taskID = nextTaskID
    nextTaskID += 1
    connectionTasks[taskID] = Task { [weak self] in
      await self?.handleConnection(socket)
      await self?.forgetTask(taskID)
    }
  }

  private func forgetTask(_ taskID: Int) {
    connectionTasks[taskID] = nil
  }

  // MARK: - Per-connection state machine: HTTP handshake, then WS frames

  private func handleConnection(_ socket: any SocketConnection) async {
    var handshake = HTTPHandshakeReader()
    var frameReader = WebSocketFrameReader()
    var connectionID: Int?

    for await chunk in socket.inbound {
      guard let id = connectionID else {
        guard let request = handshake.append(chunk) else {
          if handshake.isMalformed {
            try? await socket.send(HTTPResponseBuilder.error(status: 400, reason: "Bad Request"))
            break
          }
          continue
        }
        guard let acceptResponse = validateAndAccept(request) else {
          try? await socket.send(rejectionResponse(for: request))
          break
        }
        do {
          try await socket.send(acceptResponse)
        } catch {
          break
        }
        let id = register(socket)
        connectionID = id

        let frames = frameReader.append(handshake.leftoverBytes)
        if await process(frames, socket: socket, id: id) { break }
        continue
      }

      let frames = frameReader.append(chunk)
      if await process(frames, socket: socket, id: id) { break }
      if frameReader.protocolError { break }
    }

    if let connectionID {
      table.remove(connectionID)
      sockets[connectionID] = nil
    }
    await socket.close()
  }

  private func register(_ socket: any SocketConnection) -> Int {
    let id = table.register(
      send: { bytes in try await socket.send(bytes) },
      encodeWire: { data in
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return WebSocketFrameWriter.text(text)
      })
    sockets[id] = socket
    return id
  }

  /// `nil` means reject; a non-nil result is the `101` response bytes to send.
  private func validateAndAccept(_ request: HTTPRequestHead) -> [UInt8]? {
    guard request.method == "GET", request.path == "/control" else { return nil }
    guard let key = request.headers["sec-websocket-key"] else { return nil }
    let origin = request.headers["origin"]
    // Empty allowlist fails closed — this is not "allow all".
    guard !allowedOrigins.isEmpty, let origin, allowedOrigins.contains(origin) else {
      log("control ws: 403 rejected origin \(origin ?? "(none)")")
      return nil
    }
    return HTTPResponseBuilder.switchingProtocols(
      acceptKey: WebSocketHandshake.acceptKey(forKey: key))
  }

  private func rejectionResponse(for request: HTTPRequestHead) -> [UInt8] {
    if request.method != "GET" || request.path != "/control" {
      return HTTPResponseBuilder.error(status: 404, reason: "Not Found")
    }
    if request.headers["sec-websocket-key"] == nil {
      return HTTPResponseBuilder.error(status: 400, reason: "Bad Request")
    }
    return HTTPResponseBuilder.error(status: 403, reason: "Forbidden")
  }

  /// Processes every completed frame from one `append(_:)` call. Returns
  /// `true` once the connection should close (a close frame).
  private func process(
    _ frames: [WebSocketFrame], socket: any SocketConnection, id: Int
  ) async -> Bool {
    for frame in frames {
      switch frame.opcode {
      case .text:
        guard let text = String(bytes: frame.payload, encoding: .utf8) else { continue }
        await handle(Data(text.utf8), connection: id)
      case .binary:
        // No PCM (or any binary) on the control plane — that's ingest's job.
        log("control ws: unexpected binary frame on connection \(id) — ignored")
      case .close:
        try? await socket.send(WebSocketFrameWriter.close())
        return true
      case .ping:
        try? await socket.send(WebSocketFrameWriter.pong(payload: frame.payload))
      case .pong, .continuation:
        break  // pong: nothing to do; continuation never reaches here (reassembled already)
      }
    }
    return false
  }

  /// The same decision/apply shape as ``ControlSocketServer``'s per-line
  /// handle, with this transport's restricted capability tier.
  private func handle(_ data: Data, connection id: Int) async {
    let capabilities = Capability.controlWebSocket
    switch ControlFrameProcessor.decide(
      data, helloDone: table.helloDone(id), capabilities: capabilities, decoder: decoder)
    {
    case .respond(let requestID, let reply):
      table.respond(reply, id: requestID, to: id, using: encoder)
    case .completeHello(let requestID):
      table.markHello(id)
      table.respond(
        ControlFrameProcessor.helloReply(identity: identity, capabilities: capabilities),
        id: requestID, to: id, using: encoder)
    case .subscribe(let requestID, let params):
      // Filter registered before the snapshot — see ControlSocketServer.
      table.setSubscription(params, for: id)
      let reply = await handler(.subscribe(params))
      table.respond(reply, id: requestID, to: id, using: encoder)
    case .dispatch(let requestID, let call):
      let reply = await handler(call)
      table.respond(reply, id: requestID, to: id, using: encoder)
    }
  }
}

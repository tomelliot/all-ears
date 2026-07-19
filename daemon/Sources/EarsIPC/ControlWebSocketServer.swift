import EarsCore
import Foundation

/// The loopback WebSocket control-plane endpoint
/// (`ws://127.0.0.1:<port>/control`, `[earsd.control_ws]`) — the browser
/// extension's route to the same ``ControlRequest`` command set the CLI
/// drives over the privileged Unix socket, alongside (not replacing) that
/// socket.
///
/// Structured like ``IngestWebSocketServer`` — the same hand-rolled HTTP
/// upgrade (``HTTPHandshakeReader``) and RFC 6455 framing
/// (``WebSocketFrameReader``/``WebSocketFrameWriter``), with the Origin
/// allowlist checked *before* the `101` response, and for the same reason:
/// `NWProtocolWebSocket` exposes no pre-accept hook for path/Origin
/// validation. But where ingest accepts only `ingest.open`/`ingest.close` and
/// binary PCM, this endpoint:
///
/// - decodes the **full** ``ControlRequest`` set from text frames and
///   dispatches each to the injected handler — the *same* handler closure
///   (`ControlServer.makeHandler()`) the Unix socket server is constructed
///   with, so command dispatch is never duplicated across transports;
/// - supports `subscribe` → event-stream mode, with the per-connection
///   bounded queue, drop-oldest backpressure, and `EventFilter` fan-out
///   shared with ``ControlSocketServer`` via ``ControlConnectionTable``
///   ("subscribe is terminal" included — further text frames on a subscribed
///   connection are ignored);
/// - accepts no binary frames at all (there is no PCM on the control plane —
///   a binary frame is logged and ignored).
public actor ControlWebSocketServer {
  /// Same seam as ``ControlSocketServer/Handler`` — pass
  /// `ControlServer.makeHandler()`'s closure for both.
  public typealias Handler = @Sendable (ControlRequest) async -> ControlReply

  /// Same default and rationale as
  /// ``ControlSocketServer/defaultOutboundQueueBound``.
  public static let defaultOutboundQueueBound = 128

  private let listener: any SocketListener
  private let allowedOrigins: Set<String>
  private let handler: Handler
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
    outboundQueueBound: Int = ControlWebSocketServer.defaultOutboundQueueBound,
    log: @escaping @Sendable (String) -> Void = { _ in },
    handler: @escaping Handler
  ) {
    self.listener = listener
    self.allowedOrigins = Set(allowedOrigins)
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

  /// Fan `event` out to every subscribed connection whose filter matches —
  /// the WebSocket leg of the same live feed ``ControlSocketServer/publish(_:)``
  /// serves on the Unix socket.
  public func publish(_ event: EarsEvent) {
    table.publish(event, using: encoder)
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
    var subscribed = false

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
        if await process(frames, socket: socket, id: id, subscribed: &subscribed) { break }
        continue
      }

      let frames = frameReader.append(chunk)
      if await process(frames, socket: socket, id: id, subscribed: &subscribed) { break }
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
    _ frames: [WebSocketFrame], socket: any SocketConnection, id: Int, subscribed: inout Bool
  ) async -> Bool {
    for frame in frames {
      switch frame.opcode {
      case .text:
        if subscribed { continue }  // terminal: ignore further input once subscribed
        guard let text = String(bytes: frame.payload, encoding: .utf8) else { continue }
        if await handle(text: text, id: id) { subscribed = true }
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

  /// Process one text frame's request — the same dispatch shape as
  /// ``ControlSocketServer``'s per-line handle: peek `cmd` to distinguish a
  /// `subscribe` from a ``ControlRequest``, decode accordingly, await the
  /// handler inline so replies stay in request order. Returns `true` when the
  /// frame was a `subscribe` that transitioned the connection into
  /// event-stream mode.
  private func handle(text: String, id: Int) async -> Bool {
    guard let data = text.data(using: .utf8) else {
      table.enqueue(.failure("unrecognised request"), to: id, using: encoder)
      return false
    }
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
}

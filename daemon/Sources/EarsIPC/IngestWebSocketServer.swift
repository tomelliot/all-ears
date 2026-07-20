import EarsCore
import Foundation

/// The loopback WebSocket ingest endpoint (`ws://127.0.0.1:<port>/ingest`,
/// `[earsd.ingest_ws]`) the browser extension streams per-participant PCM
/// through — see `docs/specs/browser/transport.md` and
/// `docs/specs/capture-daemon.md` ("Audio ingestion").
///
/// ## Why this is hand-rolled instead of `Network.framework`'s `NWProtocolWebSocket`
///
/// `NWProtocolWebSocket` completes the HTTP upgrade automatically and only
/// hands the caller a connection *afterwards* — it exposes no hook to
/// inspect the request path or `Origin` header before accepting, which is
/// fatal for this endpoint's security model ("Origin header validated
/// against `allowed_origins`... No match ⇒ respond 403 and do not upgrade").
/// So the handshake and RFC 6455 framing are done directly on the same raw
/// byte transport (``SocketConnection``/``NetworkSocketListener``) the Unix
/// control socket already uses — see ``HTTPHandshakeReader``/
/// ``WebSocketFrameReader`` in this file's sibling `WebSocketFraming.swift`.
///
/// ## Ingest-only
///
/// This WebSocket accepts only `ingest.open`/`ingest.close` text frames
/// (the v1-era flat-`cmd` `IngestRequest`/`ControlResponse` shapes — the
/// ingest contract is explicitly out of control protocol v2's scope and
/// unchanged) and binary PCM frames. Every other `cmd` is rejected: the
/// daemon's control plane lives on its own transports, so an allowed Origin
/// still cannot drive the daemon from this endpoint.
///
/// ## Domain logic lives elsewhere
///
/// This actor is transport + protocol only: it validates the handshake,
/// parses frames, and dispatches to three injected handlers that own the
/// actual source/storage wiring (`EarsDaemon` in the real daemon; a fake in
/// tests). Mirrors ``EarsDaemonKit.ControlServer``'s handler-closure seam.
public actor IngestWebSocketServer {
  /// `ingest.open`: declare a stream for `source` at `format`, returning its
  /// `stream_id`. The optional ``MeetingIdentity`` is the client's membership
  /// tag — which meeting this source belongs to. Throws to report a domain
  /// failure (encoded as an `ok:false` reply) without closing the connection.
  public typealias OpenHandler =
    @Sendable (SourceID, AudioFormatSpec, MeetingIdentity?) async throws
    -> String
  /// One binary PCM frame's decoded samples for an open `stream_id`.
  public typealias PushHandler = @Sendable (String, [Float], Int) async -> Void
  /// `ingest.close`, or implicit close on connection teardown for any
  /// stream this connection opened but never explicitly closed.
  public typealias CloseHandler = @Sendable (String) async -> Void

  private let listener: any SocketListener
  private let allowedOrigins: Set<String>
  private let log: @Sendable (String) -> Void
  private let openHandler: OpenHandler
  private let pushHandler: PushHandler
  private let closeHandler: CloseHandler
  private let decoder = JSONDecoder()
  private let encoder = JSONEncoder()

  private var connectionTasks: [Int: Task<Void, Never>] = [:]
  private var nextConnectionID = 0

  /// - Parameters:
  ///   - allowedOrigins: `[earsd.ingest_ws].allowed_origins`. Empty rejects
  ///     every connection (fail closed) — this is not "allow all".
  public init(
    listener: any SocketListener,
    allowedOrigins: [String],
    log: @escaping @Sendable (String) -> Void = { _ in },
    onOpen: @escaping OpenHandler,
    onPush: @escaping PushHandler,
    onClose: @escaping CloseHandler
  ) {
    self.listener = listener
    self.allowedOrigins = Set(allowedOrigins)
    self.log = log
    self.openHandler = onOpen
    self.pushHandler = onPush
    self.closeHandler = onClose
  }

  /// Accept connections until the listener closes.
  public func run() async {
    for await socket in listener.connections {
      accept(socket)
    }
  }

  /// Stop listening and tear down every open connection (closing whatever
  /// ingest streams each still had open).
  public func shutdown() async {
    await listener.close()
    let tasks = connectionTasks
    connectionTasks = [:]
    for (_, task) in tasks { task.cancel() }
  }

  private func accept(_ socket: any SocketConnection) {
    let id = nextConnectionID
    nextConnectionID += 1
    connectionTasks[id] = Task { [weak self] in
      await self?.handleConnection(socket)
      await self?.forget(id)
    }
  }

  private func forget(_ id: Int) {
    connectionTasks[id] = nil
  }

  // MARK: - Per-connection state machine: HTTP handshake, then WS frames

  private struct OpenStream {
    var format: AudioFormatSpec
  }

  private func handleConnection(_ socket: any SocketConnection) async {
    var handshake = HTTPHandshakeReader()
    var frameReader = WebSocketFrameReader()
    var upgraded = false
    var openStreams: [String: OpenStream] = [:]

    for await chunk in socket.inbound {
      if !upgraded {
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
        upgraded = true

        let frames = frameReader.append(handshake.leftoverBytes)
        if await process(frames, socket: socket, openStreams: &openStreams) { break }
        continue
      }

      let frames = frameReader.append(chunk)
      if await process(frames, socket: socket, openStreams: &openStreams) { break }
      if frameReader.protocolError { break }
    }

    await socket.close()
    for streamID in openStreams.keys { await closeHandler(streamID) }
  }

  /// `nil` means reject; a non-nil result is the `101` response bytes to send.
  private func validateAndAccept(_ request: HTTPRequestHead) -> [UInt8]? {
    guard request.method == "GET", request.path == "/ingest" else { return nil }
    guard let key = request.headers["sec-websocket-key"] else { return nil }
    let origin = request.headers["origin"]
    // Empty allowlist fails closed — this is not "allow all".
    guard !allowedOrigins.isEmpty, let origin, allowedOrigins.contains(origin) else {
      log("ingest ws: 403 rejected origin \(origin ?? "(none)")")
      return nil
    }
    return HTTPResponseBuilder.switchingProtocols(
      acceptKey: WebSocketHandshake.acceptKey(forKey: key))
  }

  private func rejectionResponse(for request: HTTPRequestHead) -> [UInt8] {
    if request.method != "GET" || request.path != "/ingest" {
      return HTTPResponseBuilder.error(status: 404, reason: "Not Found")
    }
    if request.headers["sec-websocket-key"] == nil {
      return HTTPResponseBuilder.error(status: 400, reason: "Bad Request")
    }
    return HTTPResponseBuilder.error(status: 403, reason: "Forbidden")
  }

  /// Processes every completed frame from one `append(_:)` call. Returns
  /// `true` once the connection should close (a close frame, or a transport
  /// write failure).
  private func process(
    _ frames: [WebSocketFrame], socket: any SocketConnection,
    openStreams: inout [String: OpenStream]
  ) async -> Bool {
    for frame in frames {
      switch frame.opcode {
      case .text:
        guard let text = String(bytes: frame.payload, encoding: .utf8) else { continue }
        await handleControlFrame(text, socket: socket, openStreams: &openStreams)
      case .binary:
        await handleBinaryFrame(frame.payload, openStreams: openStreams)
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

  // MARK: - Control frames: ingest.open / ingest.close, everything else rejected

  private func handleControlFrame(
    _ text: String, socket: any SocketConnection, openStreams: inout [String: OpenStream]
  ) async {
    guard let data = text.data(using: .utf8),
      let request = try? decoder.decode(IngestRequest.self, from: data)
    else {
      try? await socket.send(
        WebSocketFrameWriter.text(failureText("unsupported cmd on the ingest WebSocket")))
      return
    }
    switch request {
    case .open(let source, let format, let meeting):
      do {
        let streamID = try await openHandler(source, format, meeting)
        openStreams[streamID] = OpenStream(format: format)
        try? await socket.send(
          WebSocketFrameWriter.text(
            replyText(ControlResponse<IngestOpenData>.success(IngestOpenData(streamID: streamID)))))
      } catch {
        try? await socket.send(
          WebSocketFrameWriter.text(
            replyText(ControlResponse<IngestOpenData>.failure(ControlError("\(error)")))))
      }
    case .close(let streamID):
      openStreams.removeValue(forKey: streamID)
      await closeHandler(streamID)
      try? await socket.send(
        WebSocketFrameWriter.text(replyText(ControlResponse<EmptyData>.success(EmptyData()))))
    }
  }

  // MARK: - Binary PCM frames: [u8 idLen][stream_id][pcm_s16le bytes]

  private func handleBinaryFrame(_ payload: [UInt8], openStreams: [String: OpenStream]) async {
    guard let idLen = payload.first else { return }
    let idLength = Int(idLen)
    guard payload.count >= 1 + idLength else {
      log("ingest ws: malformed binary frame (idLen past end) — dropped")
      return
    }
    guard let streamID = String(bytes: payload[1..<(1 + idLength)], encoding: .ascii) else {
      return
    }
    guard let stream = openStreams[streamID] else {
      log("ingest ws: pcm for unknown stream \(streamID) — dropped")
      return
    }
    let samples = Self.decodePCM16LE(payload[(1 + idLength)...])
    await pushHandler(streamID, samples, stream.format.sampleRate)
  }

  private static func decodePCM16LE(_ bytes: ArraySlice<UInt8>) -> [Float] {
    var samples: [Float] = []
    samples.reserveCapacity(bytes.count / 2)
    var iterator = bytes.makeIterator()
    while let low = iterator.next(), let high = iterator.next() {
      let raw = Int16(bitPattern: UInt16(low) | (UInt16(high) << 8))
      samples.append(Float(raw) / 32768.0)
    }
    return samples
  }

  // MARK: - Reply encoding

  private func replyText<Payload>(_ response: ControlResponse<Payload>) -> String {
    guard let data = try? encoder.encode(response), let text = String(data: data, encoding: .utf8)
    else {
      return "{\"ok\":false,\"error\":\"internal encode error\"}"
    }
    return text
  }

  private func failureText(_ message: String) -> String {
    replyText(ControlResponse<EmptyData>.failure(ControlError(message)))
  }
}

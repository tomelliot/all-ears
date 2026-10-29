import Foundation

/// The v2 request envelope: `{"id": …, "method": "…", "params": {…}}` — one
/// JSON object per line (Unix socket) or per text frame (WebSocket). `id` is
/// client-chosen and echoed verbatim on the response, which is what makes
/// out-of-order completion legal.
///
/// `hello` is representable here (``ControlRequestFrame/hello(id:params:)``)
/// so clients can encode it, but decodes to its own case rather than a
/// ``ControlCall`` — servers handle the handshake in the transport layer.
public enum ControlRequestFrame: Sendable, Hashable {
  case hello(id: RequestID, params: HelloParams)
  case call(id: RequestID, call: ControlCall)

  public var id: RequestID {
    switch self {
    case .hello(let id, _): id
    case .call(let id, _): id
    }
  }
}

/// A lenient first-pass decode of just the envelope's `id` and `method`, so a
/// server can still answer a malformed or unknown request with a correlated
/// error instead of failing to decode anything at all.
public struct ControlRequestHead: Sendable, Decodable {
  public var id: RequestID?
  public var method: String?
}

/// `hello`'s params: the requested protocol version and a free-form client
/// identifier for logs.
public struct HelloParams: Sendable, Hashable, Codable {
  public var protocolVersion: Int
  public var client: String?

  public init(protocolVersion: Int = ControlProtocolV2.version, client: String? = nil) {
    self.protocolVersion = protocolVersion
    self.client = client
  }

  private enum CodingKeys: String, CodingKey {
    case protocolVersion = "protocol"
    case client
  }
}

/// `hello`'s result: the negotiated version, the daemon's identity, the
/// boot id revision counters are scoped to, and this *connection's*
/// capability set.
public struct HelloResult: Sendable, Hashable, Codable {
  public var protocolVersion: Int
  public var daemon: String
  /// Fresh per daemon start; a reconnecting client compares it to detect a
  /// restart (in-memory state and revs are not comparable across boots).
  public var bootID: String
  public var capabilities: [Capability]

  public init(
    protocolVersion: Int = ControlProtocolV2.version, daemon: String, bootID: String,
    capabilities: [Capability]
  ) {
    self.protocolVersion = protocolVersion
    self.daemon = daemon
    self.bootID = bootID
    self.capabilities = capabilities
  }

  private enum CodingKeys: String, CodingKey {
    case protocolVersion = "protocol"
    case daemon
    case bootID = "boot_id"
    case capabilities
  }
}

// MARK: - Envelope Codable

extension ControlRequestFrame: Codable {
  private enum CodingKeys: String, CodingKey {
    case id, method, params
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let id = try container.decode(RequestID.self, forKey: .id)
    let rawMethod = try container.decode(String.self, forKey: .method)
    guard let method = ControlMethod(rawValue: rawMethod) else {
      throw DecodingError.dataCorruptedError(
        forKey: .method, in: container, debugDescription: "unknown method '\(rawMethod)'")
    }
    if method == .hello {
      self = .hello(id: id, params: try container.decode(HelloParams.self, forKey: .params))
      return
    }
    self = .call(id: id, call: try Self.decodeCall(method, from: container))
  }

  private static func decodeCall(
    _ method: ControlMethod, from container: KeyedDecodingContainer<CodingKeys>
  ) throws -> ControlCall {
    switch method {
    case .hello:
      preconditionFailure("hello is decoded by init(from:)")
    case .status:
      return .status
    case .subscribe:
      return .subscribe(
        try container.decodeIfPresent(SubscribeParams.self, forKey: .params) ?? SubscribeParams())
    case .sessionStart:
      return .sessionStart(
        try container.decodeIfPresent(SessionStartParams.self, forKey: .params)
          ?? SessionStartParams())
    case .sessionEnd:
      return .sessionEnd(session: try container.decode(SessionRef.self, forKey: .params).session)
    case .sessionPause:
      return .sessionPause(session: try container.decode(SessionRef.self, forKey: .params).session)
    case .sessionResume:
      return .sessionResume(session: try container.decode(SessionRef.self, forKey: .params).session)
    case .sessionRename:
      return .sessionRename(try container.decode(SessionRenameParams.self, forKey: .params))
    case .sessionAttendee:
      return .sessionAttendee(try container.decode(SessionAttendeeParams.self, forKey: .params))
    case .sessionList:
      return .sessionList
    case .sessionGet:
      return .sessionGet(session: try container.decode(SessionRef.self, forKey: .params).session)
    case .sessionRetry:
      return .sessionRetry(try container.decode(SessionRetryParams.self, forKey: .params))
    case .segmentPublish:
      return .segmentPublish(try container.decode(SegmentPublishParams.self, forKey: .params))
    case .jobPublish:
      return .jobPublish(try container.decode(JobPublishParams.self, forKey: .params))
    case .sourcesList:
      return .sourcesList
    case .sourcesAdd:
      let params = try container.nestedContainer(keyedBy: SpecKeys.self, forKey: .params)
      return .sourcesAdd(try params.decode(SourceSpec.self, forKey: .spec))
    case .sourcesRemove:
      return .sourcesRemove(
        source: try container.decode(SourceRef.self, forKey: .params).source)
    case .sourcesEnable:
      return .sourcesEnable(
        source: try container.decode(SourceRef.self, forKey: .params).source)
    case .sourcesDisable:
      return .sourcesDisable(
        source: try container.decode(SourceRef.self, forKey: .params).source)
    case .capturePause:
      let params = try container.decodeIfPresent(OptionalSourceRef.self, forKey: .params)
      return .capturePause(source: params?.source)
    case .captureResume:
      let params = try container.decodeIfPresent(OptionalSourceRef.self, forKey: .params)
      return .captureResume(source: params?.source)
    case .flush:
      return .flush
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .hello(let id, let params):
      try container.encode(id, forKey: .id)
      try container.encode(ControlMethod.hello, forKey: .method)
      try container.encode(params, forKey: .params)
    case .call(let id, let call):
      try container.encode(id, forKey: .id)
      try container.encode(call.method, forKey: .method)
      try encodeParams(of: call, into: &container)
    }
  }

  private func encodeParams(
    of call: ControlCall, into container: inout KeyedEncodingContainer<CodingKeys>
  ) throws {
    switch call {
    case .status, .sessionList, .sourcesList, .flush:
      break  // no params
    case .subscribe(let params):
      try container.encode(params, forKey: .params)
    case .sessionStart(let params):
      try container.encode(params, forKey: .params)
    case .sessionEnd(let session), .sessionPause(let session), .sessionResume(let session),
      .sessionGet(let session):
      try container.encode(SessionRef(session: session), forKey: .params)
    case .sessionRename(let params):
      try container.encode(params, forKey: .params)
    case .sessionRetry(let params):
      try container.encode(params, forKey: .params)
    case .sessionAttendee(let params):
      try container.encode(params, forKey: .params)
    case .segmentPublish(let params):
      try container.encode(params, forKey: .params)
    case .jobPublish(let params):
      try container.encode(params, forKey: .params)
    case .sourcesAdd(let spec):
      var params = container.nestedContainer(keyedBy: SpecKeys.self, forKey: .params)
      try params.encode(spec, forKey: .spec)
    case .sourcesRemove(let source), .sourcesEnable(let source), .sourcesDisable(let source):
      try container.encode(SourceRef(source: source), forKey: .params)
    case .capturePause(let source), .captureResume(let source):
      if let source {
        try container.encode(SourceRef(source: source), forKey: .params)
      }
    }
  }

  // MARK: - Small param shapes shared by several methods

  private struct SessionRef: Codable {
    var session: String

    private enum CodingKeys: String, CodingKey {
      case session
    }
  }
  private struct SourceRef: Codable {
    var source: SourceID
  }
  private struct OptionalSourceRef: Codable {
    var source: SourceID?
  }
  private enum SpecKeys: String, CodingKey {
    case spec
  }
}

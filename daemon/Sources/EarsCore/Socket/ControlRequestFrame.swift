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
    case .meetingStart:
      return .meetingStart(
        try container.decodeIfPresent(MeetingStartParams.self, forKey: .params)
          ?? MeetingStartParams())
    case .meetingEnd:
      return .meetingEnd(meeting: try container.decode(MeetingRef.self, forKey: .params).meeting)
    case .meetingPause:
      return .meetingPause(meeting: try container.decode(MeetingRef.self, forKey: .params).meeting)
    case .meetingResume:
      return .meetingResume(meeting: try container.decode(MeetingRef.self, forKey: .params).meeting)
    case .meetingRename:
      return .meetingRename(try container.decode(MeetingRenameParams.self, forKey: .params))
    case .meetingAttendee:
      return .meetingAttendee(try container.decode(MeetingAttendeeParams.self, forKey: .params))
    case .meetingList:
      return .meetingList
    case .meetingGet:
      return .meetingGet(meeting: try container.decode(MeetingRef.self, forKey: .params).meeting)
    case .sessionOpen:
      return .sessionOpen(try container.decode(SessionOpenParams.self, forKey: .params))
    case .sessionClose:
      return .sessionClose(id: try container.decode(SessionRef.self, forKey: .params).id)
    case .sessionList:
      return .sessionList
    case .sessionAddSource:
      let params = try container.decode(SessionAddSourceRef.self, forKey: .params)
      return .sessionAddSource(id: params.id, source: params.source)
    case .mark:
      let params = try container.nestedContainer(keyedBy: MarkKeys.self, forKey: .params)
      return .mark(
        sources: try params.decode([SourceID].self, forKey: .sources),
        slug: try params.decode(String.self, forKey: .slug),
        range: try decodeMarkRange(from: params))
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
    case .status, .meetingList, .sessionList, .sourcesList, .flush:
      break  // no params
    case .subscribe(let params):
      try container.encode(params, forKey: .params)
    case .meetingStart(let params):
      try container.encode(params, forKey: .params)
    case .meetingEnd(let meeting), .meetingPause(let meeting), .meetingResume(let meeting),
      .meetingGet(let meeting):
      try container.encode(MeetingRef(meeting: meeting), forKey: .params)
    case .meetingRename(let params):
      try container.encode(params, forKey: .params)
    case .meetingAttendee(let params):
      try container.encode(params, forKey: .params)
    case .sessionOpen(let params):
      try container.encode(params, forKey: .params)
    case .sessionClose(let id):
      try container.encode(SessionRef(id: id), forKey: .params)
    case .sessionAddSource(let id, let source):
      try container.encode(SessionAddSourceRef(id: id, source: source), forKey: .params)
    case .mark(let sources, let slug, let range):
      var params = container.nestedContainer(keyedBy: MarkKeys.self, forKey: .params)
      try params.encode(sources, forKey: .sources)
      try params.encode(slug, forKey: .slug)
      switch range {
      case .lastSeconds(let seconds):
        try params.encode(seconds, forKey: .lastSeconds)
      case .absolute(let start, let end):
        try params.encodeISO8601Instant(start, forKey: .start)
        try params.encodeISO8601Instant(end, forKey: .end)
      }
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

  private struct MeetingRef: Codable {
    var meeting: String
  }
  private struct SessionRef: Codable {
    var id: String
  }
  private struct SessionAddSourceRef: Codable {
    var id: String
    var source: SourceID
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
  private enum MarkKeys: String, CodingKey {
    case sources, slug, start, end
    case lastSeconds = "last_seconds"
  }

  /// `mark`'s dual-shape range: exactly one of `last_seconds` or
  /// `start`+`end` — see ``MarkRange``.
  private static func decodeMarkRange(
    from container: KeyedDecodingContainer<MarkKeys>
  ) throws -> MarkRange {
    let lastSeconds = try container.decodeIfPresent(Double.self, forKey: .lastSeconds)
    let hasAbsolute = container.contains(.start) || container.contains(.end)
    switch (lastSeconds, hasAbsolute) {
    case (let seconds?, false):
      return .lastSeconds(seconds)
    case (nil, true):
      return .absolute(
        start: try container.decodeISO8601Instant(forKey: .start),
        end: try container.decodeISO8601Instant(forKey: .end))
    case (nil, false):
      throw DecodingError.dataCorruptedError(
        forKey: .lastSeconds, in: container,
        debugDescription: "mark requires either last_seconds or start+end")
    case (_, true):
      throw DecodingError.dataCorruptedError(
        forKey: .lastSeconds, in: container,
        debugDescription: "mark accepts either last_seconds or start+end, not both")
    }
  }
}

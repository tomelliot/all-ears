/// The v2 response envelope — exactly one per request, MAY arrive out of
/// order, correlated by the echoed `id`:
///
/// ```jsonc
/// {"id": 7, "result": {…}}
/// {"id": 7, "error": {"code": "meeting_not_found", "message": "…"}}
/// ```
///
/// Generic over the result payload the caller expects, mirroring how v1's
/// `ControlResponse<Payload>` worked: the caller knows what it asked for and
/// decodes `result` accordingly. Servers encode through the type-erased
/// `EarsIPC.ControlReply` instead (one handler can't name every payload type).
public enum ControlResponseFrame<Payload: Codable & Sendable & Hashable>: Sendable, Hashable {
  case result(id: RequestID, Payload)
  case error(id: RequestID, WireError)

  public var id: RequestID {
    switch self {
    case .result(let id, _): id
    case .error(let id, _): id
    }
  }

  /// The payload, or the error as a thrown ``WireError``.
  public func get() throws -> Payload {
    switch self {
    case .result(_, let payload): return payload
    case .error(_, let error): throw error
    }
  }
}

extension ControlResponseFrame: Codable {
  private enum CodingKeys: String, CodingKey {
    case id, result, error
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let id = try container.decode(RequestID.self, forKey: .id)
    if container.contains(.error) {
      self = .error(id: id, try container.decode(WireError.self, forKey: .error))
    } else {
      self = .result(id: id, try container.decode(Payload.self, forKey: .result))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .result(let id, let payload):
      try container.encode(id, forKey: .id)
      try container.encode(payload, forKey: .result)
    case .error(let id, let error):
      try container.encode(id, forKey: .id)
      try container.encode(error, forKey: .error)
    }
  }
}

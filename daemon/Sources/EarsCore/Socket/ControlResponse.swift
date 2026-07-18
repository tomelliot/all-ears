/// A control-socket response envelope, per `docs/specs/capture-daemon.md`'s
/// literal `status` example:
///
/// ```jsonc
/// {"ok":true,"data":{"uptime_s":3600,"sources":[{"id":"mic","state":"capturing","codec":"aac"}]}}
/// ```
///
/// and the corresponding failure shape this suite adopts for the `ok:false`
/// case the spec's prose implies but doesn't show literally:
///
/// ```jsonc
/// {"ok":false,"error":"<message>"}
/// ```
///
/// The response JSON carries no `cmd` tag of its own — a caller already
/// knows what request it sent, and decodes `data` accordingly. So rather
/// than an existential/enum-of-every-payload, `ControlResponse` is generic
/// over ``Payload``: `ControlResponse<StatusData>` for a `status` reply,
/// `ControlResponse<IngestOpenData>` for `ingest.open`, and so on for each
/// command's response payload type.
public enum ControlResponse<Payload: Codable & Sendable & Hashable>: Sendable, Hashable {
  case success(Payload)
  case failure(ControlError)
}

extension ControlResponse: Codable {
  private enum CodingKeys: String, CodingKey {
    case ok, data, error
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let ok = try container.decode(Bool.self, forKey: .ok)
    if ok {
      self = .success(try container.decode(Payload.self, forKey: .data))
    } else {
      self = .failure(try container.decode(ControlError.self, forKey: .error))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .success(let payload):
      try container.encode(true, forKey: .ok)
      try container.encode(payload, forKey: .data)
    case .failure(let error):
      try container.encode(false, forKey: .ok)
      try container.encode(error, forKey: .error)
    }
  }
}

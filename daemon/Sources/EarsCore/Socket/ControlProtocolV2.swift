/// Control protocol v2 fundamentals, per
/// `docs/specs/control-protocol.md`: the protocol version the `hello`
/// handshake negotiates, the per-connection capability set, the stable
/// machine-readable error codes, and the client-chosen request id that
/// correlates every response with its request.
public enum ControlProtocolV2 {
  /// The one protocol version this build speaks. `hello` requests naming any
  /// other version are answered with `unsupported_protocol`.
  public static let version = 2
}

/// What a connection may do, assigned by transport at connect time and
/// advertised in `hello`'s result (`docs/specs/control-protocol.md`'s
/// "Transports & privilege"): the Unix socket gets all five; the loopback
/// control WebSocket gets `observe` + `meetings` only.
public enum Capability: String, Sendable, Hashable, Codable, CaseIterable {
  /// `status` + `subscribe` (snapshot + live feed).
  case observe
  /// The `meeting.*` lifecycle verbs.
  case meetings
  /// Session lifecycle (`session.*`, `mark`) and the notification-only
  /// publishes (`segment.publish`, `job.publish`).
  case sessions
  /// `sources.list` / `sources.enable` / `sources.disable`.
  case sources
  /// Runtime source mutation and capture control: `sources.add`/`remove`,
  /// `capture.pause`/`resume`, `flush`.
  case admin

  /// The full set — the Unix socket's privilege tier.
  public static let all: Set<Capability> = Set(allCases)
  /// The loopback control WebSocket's tier: the extension only ever needed
  /// meeting verbs plus observation.
  public static let controlWebSocket: Set<Capability> = [.observe, .meetings]
}

/// The stable machine-readable identifiers carried in `error.code` — clients
/// switch on these, never on `message` (which is human prose).
public enum ControlErrorCode: String, Sendable, Hashable, Codable, CaseIterable {
  case helloRequired = "hello_required"
  case unsupportedProtocol = "unsupported_protocol"
  case invalidRequest = "invalid_request"
  case unknownMethod = "unknown_method"
  case notPermitted = "not_permitted"
  case meetingNotFound = "meeting_not_found"
  case meetingEnded = "meeting_ended"
  case sessionNotFound = "session_not_found"
  case sessionAlreadyClosed = "session_already_closed"
  case sourceNotFound = "source_not_found"
  /// A failed `if_rev` compare-and-set (`meeting.rename`).
  case conflict
  case internalError = "internal"
}

/// The `error` object of a failed v2 response:
/// `{"code":"meeting_not_found","message":"no active meeting 0d5e…"}`.
public struct WireError: Error, Sendable, Hashable, Codable {
  public var code: ControlErrorCode
  /// Human prose, never load-bearing.
  public var message: String

  public init(code: ControlErrorCode, message: String) {
    self.code = code
    self.message = message
  }
}

/// A client-chosen request id, echoed verbatim in the response — any JSON
/// string or number. Distinguishing `int` from `double` preserves `7` as `7`
/// (not `7.0`) on the echo; `none` covers protocol-level error responses to
/// requests whose id could not even be decoded (`"id": null` on the wire).
public enum RequestID: Sendable, Hashable {
  case int(Int64)
  case double(Double)
  case string(String)
  case none
}

extension RequestID: Codable {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .none
    } else if let value = try? container.decode(Int64.self) {
      self = .int(value)
    } else if let value = try? container.decode(Double.self) {
      self = .double(value)
    } else {
      self = .string(try container.decode(String.self))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .int(let value): try container.encode(value)
    case .double(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .none: try container.encodeNil()
    }
  }
}

extension RequestID: CustomStringConvertible {
  public var description: String {
    switch self {
    case .int(let value): "\(value)"
    case .double(let value): "\(value)"
    case .string(let value): value
    case .none: "null"
    }
  }
}

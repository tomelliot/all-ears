/// The `error` payload of a failed ``ControlResponse``:
/// `{"ok":false,"error":"<message>"}`. A plain string on the wire — the
/// spec gives no richer error shape (only the success example), so this
/// stays minimal rather than inventing an error-code taxonomy that isn't
/// specified anywhere.
public struct ControlError: Sendable, Hashable {
  public var message: String

  public init(_ message: String) {
    self.message = message
  }
}

extension ControlError: Codable {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    self.message = try container.decode(String.self)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(message)
  }
}

extension ControlError: ExpressibleByStringLiteral {
  public init(stringLiteral value: String) {
    self.init(value)
  }
}

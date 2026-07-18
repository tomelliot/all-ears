/// A single config validation problem, carrying enough structure — the full key
/// path and a machine-distinguishable reason — that a caller can format it
/// however it likes (e.g. `"log.level: expected string, got integer"`). This is
/// the "no silent fallback" requirement from `docs/configuration.md`: every tool
/// exits non-zero with a precise key-path-plus-reason message on invalid config.
public struct ConfigError: Sendable, Hashable, Error {
  public enum Reason: Sendable, Hashable {
    /// The key isn't part of the declared schema (and isn't a passthrough
    /// key belonging to a not-yet-implemented schema slice).
    case unknownKey
    /// The value at this key path is the wrong `ConfigValueKind`.
    case typeMismatch(expected: ConfigValueKind, got: ConfigValueKind)

    /// The reason phrase, e.g. `"unknown key"` or `"expected string, got
    /// integer"`.
    public var message: String {
      switch self {
      case .unknownKey:
        "unknown key"
      case .typeMismatch(let expected, let got):
        "expected \(expected.description), got \(got.description)"
      }
    }
  }

  /// The full path to the offending key, e.g. `["log", "level"]`.
  public var keyPath: [String]
  public var reason: Reason

  public init(keyPath: [String], reason: Reason) {
    self.keyPath = keyPath
    self.reason = reason
  }

  /// The key path rendered dot-joined, e.g. `"log.level"`.
  public var keyPathString: String {
    keyPath.joined(separator: ".")
  }

  /// The full precise message: key path plus reason, e.g. `"log.level:
  /// expected string, got integer"`.
  public var message: String {
    "\(keyPathString): \(reason.message)"
  }
}

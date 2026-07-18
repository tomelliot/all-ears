/// A TOML-library-agnostic in-memory config value tree.
///
/// The pure config layering/merge/validation engine (see `ConfigMerge.swift` and
/// `ConfigValidation.swift`) operates entirely on this type rather than on
/// TOMLKit's own value types, so `EarsCore` never needs to import TOMLKit or any
/// other I/O-adjacent dependency. `EarsConfig` owns converting `TOMLTable` /
/// `TOMLValueConvertible` to and from `ConfigValue` (see `docs/configuration.md`
/// for the layering model this tree is built from).
public enum ConfigValue: Sendable, Hashable {
  case string(String)
  case int(Int)
  case bool(Bool)
  case double(Double)
  case array([ConfigValue])
  case table([String: ConfigValue])

  /// This value's kind, used to report schema validation errors precisely
  /// (e.g. "expected string, got integer").
  public var kind: ConfigValueKind {
    switch self {
    case .string: .string
    case .int: .int
    case .bool: .bool
    case .double: .double
    case .array: .array
    case .table: .table
    }
  }
}

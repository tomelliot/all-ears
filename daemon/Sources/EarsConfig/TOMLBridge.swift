import EarsCore
import TOMLKit

/// Bridges TOMLKit's `TOMLTable` / `TOMLValueConvertible` to and from
/// `EarsCore`'s TOML-library-agnostic `ConfigValue` tree. This is the only
/// place in the suite that imports both `EarsCore`'s config types and TOMLKit
/// together — `EarsCore` itself stays dependency-free (see
/// `Sources/EarsCore/Config/ConfigValue.swift`).
enum TOMLBridge {
  /// Converts a parsed `TOMLTable` (a whole document, or a nested table) into
  /// a `ConfigValue.table`.
  static func configValue(from table: TOMLTable) -> ConfigValue {
    var result: [String: ConfigValue] = [:]
    for (key, value) in table {
      result[key] = configValue(from: value)
    }
    return .table(result)
  }

  /// Converts a single TOML value into its `ConfigValue` equivalent.
  static func configValue(from value: TOMLValueConvertible) -> ConfigValue {
    switch value.type {
    case .string:
      return .string(value.string ?? "")
    case .int:
      return .int(value.int ?? 0)
    case .double:
      return .double(value.double ?? 0)
    case .bool:
      return .bool(value.bool ?? false)
    case .table:
      guard let table = value.table else { return .table([:]) }
      return configValue(from: table)
    case .array:
      guard let array = value.array else { return .array([]) }
      return .array(array.map(configValue(from:)))
    case .date, .time, .dateTime:
      // Phase 0's schema has no date/time-valued keys. Render as TOML text
      // rather than silently dropping the value; a later phase's schema
      // can give these a proper ConfigValue case if it needs one.
      return .string(value.debugDescription)
    }
  }

  /// Converts a `ConfigValue` into a `TOMLValueConvertible` suitable for
  /// insertion into a `TOMLTable`/`TOMLArray`.
  static func tomlValue(from value: ConfigValue) -> TOMLValueConvertible {
    switch value {
    case .string(let string):
      return string
    case .int(let int):
      return int
    case .bool(let bool):
      return bool
    case .double(let double):
      return double
    case .array(let array):
      return TOMLArray(array.map(tomlValue(from:)))
    case .table(let table):
      return tomlTable(from: table)
    }
  }

  private static func tomlTable(from table: [String: ConfigValue]) -> TOMLTable {
    let tomlTable = TOMLTable()
    for (key, value) in table.sorted(by: { $0.key < $1.key }) {
      tomlTable[key] = tomlValue(from: value)
    }
    return tomlTable
  }

  /// Serializes a `ConfigValue` tree back to TOML text, for `--print-config`.
  /// Keys are emitted in sorted order so the output is deterministic. A
  /// non-table root (which should never occur for a real config tree)
  /// serializes to an empty document.
  static func serialize(_ value: ConfigValue) -> String {
    guard case .table(let table) = value else {
      return ""
    }
    return tomlTable(from: table).convert(to: .toml)
  }
}

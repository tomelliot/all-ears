import EarsCore

/// Pulls typed scalar fields out of a `ConfigValue.table`, shared by
/// ``SourceDescriptorTOML`` and ``SessionDescriptorTOML``'s decoders so
/// neither repeats the same "missing or wrong kind" boilerplate.
struct TOMLFieldReader {
  let table: [String: ConfigValue]

  func string(_ key: String) throws(DescriptorTOMLError) -> String {
    guard case .string(let value)? = table[key] else {
      throw .missingField(key)
    }
    return value
  }

  func int(_ key: String) throws(DescriptorTOMLError) -> Int {
    guard case .int(let value)? = table[key] else {
      throw .missingField(key)
    }
    return value
  }

  func bool(_ key: String) throws(DescriptorTOMLError) -> Bool {
    guard case .bool(let value)? = table[key] else {
      throw .missingField(key)
    }
    return value
  }

  func array(_ key: String) throws(DescriptorTOMLError) -> [ConfigValue] {
    guard case .array(let value)? = table[key] else {
      throw .missingField(key)
    }
    return value
  }

  /// An optional string field: an empty string or an absent key both decode
  /// to `nil`, matching the "empty => absent" sentinel convention this
  /// codebase already uses for optional path-like fields (`socket_path`,
  /// `log.file`).
  func optionalString(_ key: String) -> String? {
    guard case .string(let value)? = table[key], !value.isEmpty else {
      return nil
    }
    return value
  }

  /// An int field that defaults rather than throws when absent -- for a
  /// field added after some on-disk files already existed without it (e.g.
  /// `session.toml`'s `pre_roll_seconds`), so an older file still decodes
  /// cleanly instead of failing on a "missing field" error.
  func optionalInt(_ key: String, default defaultValue: Int) -> Int {
    guard case .int(let value)? = table[key] else {
      return defaultValue
    }
    return value
  }
}

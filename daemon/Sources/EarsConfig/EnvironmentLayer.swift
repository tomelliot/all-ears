import EarsCore

/// Builds the `EARS_*` environment-variable config layer, per
/// `docs/configuration.md`: prefix `EARS_`, nested keys joined by `__`
/// (`EARS_LOG__LEVEL` → `log.level`). `EARS_CONFIG` is excluded — it selects
/// which file to read (see `resolveConfigFilePath`), not a config value itself.
///
/// Environment variables are always strings at the OS level; each value is
/// coerced to `bool`, `int`, or `double` when it unambiguously parses as one,
/// else left as `string`. Without this, `EARS_LOG__OSLOG=false` would merge in
/// as `ConfigValue.string("false")` and fail Phase 0 validation's `Bool` check
/// for `log.oslog` even though the intent is unambiguous.
///
/// Takes the environment as a parameter rather than reading
/// `ProcessInfo.processInfo.environment` directly, so it's a pure, injectable
/// function tests can exercise without mutating real process state.
public func configLayer(fromEnvironment environment: [String: String]) -> ConfigValue {
  let prefix = "EARS_"
  var root: [String: ConfigValue] = [:]

  for (key, rawValue) in environment {
    guard key.hasPrefix(prefix), key != "EARS_CONFIG" else { continue }
    let remainder = String(key.dropFirst(prefix.count))
    guard !remainder.isEmpty else { continue }

    let pathComponents = remainder.components(separatedBy: "__").map { $0.lowercased() }
    insert(coerce(rawValue), at: pathComponents, into: &root)
  }

  return .table(root)
}

private func insert(
  _ value: ConfigValue, at path: [String], into table: inout [String: ConfigValue]
) {
  guard let first = path.first else { return }

  guard path.count > 1 else {
    table[first] = value
    return
  }

  var nested: [String: ConfigValue] = [:]
  if case .table(let existing)? = table[first] {
    nested = existing
  }
  insert(value, at: Array(path.dropFirst()), into: &nested)
  table[first] = .table(nested)
}

private func coerce(_ rawValue: String) -> ConfigValue {
  if let boolValue = boolLiteral(rawValue) {
    return .bool(boolValue)
  }
  if let intValue = Int(rawValue) {
    return .int(intValue)
  }
  if let doubleValue = Double(rawValue) {
    return .double(doubleValue)
  }
  return .string(rawValue)
}

private func boolLiteral(_ rawValue: String) -> Bool? {
  switch rawValue.lowercased() {
  case "true": return true
  case "false": return false
  default: return nil
  }
}

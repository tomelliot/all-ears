import EarsCore

/// The `--log-level`/`--log-file` flags every tool supports (see
/// `docs/configuration.md`'s "every tool supports --print-config ... and
/// --config-path" discovery convention, and the sibling CLI-flag layering
/// requirement it documents alongside `EARS_*` env vars). Both are optional:
/// `nil` means the flag wasn't passed, so it must not override a lower layer.
public struct CLILogFlags: Sendable {
  public var level: String?
  public var file: String?

  public init(level: String? = nil, file: String? = nil) {
    self.level = level
    self.file = file
  }
}

/// Builds the highest-precedence config layer from parsed CLI flags, per
/// `docs/configuration.md`'s layering model (defaults → file → env → flags).
/// Mirrors ``configLayer(fromEnvironment:)``'s "only set what was actually
/// provided" shape: an unset flag contributes nothing, so it never clobbers
/// the file or environment layer beneath it.
public func configLayer(fromCLIFlags flags: CLILogFlags) -> ConfigValue {
  var log: [String: ConfigValue] = [:]
  if let level = flags.level {
    log["level"] = .string(level)
  }
  if let file = flags.file {
    log["file"] = .string(file)
  }
  guard !log.isEmpty else { return .table([:]) }
  return .table(["log": .table(log)])
}

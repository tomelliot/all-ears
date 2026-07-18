import EarsCore
import TOMLKit

/// Inputs an executable gathers before calling ``loadConfig(_:)``: its
/// `--config` flag (if any), the process environment, the user's home
/// directory, and its already-parsed CLI flag overrides.
public struct ConfigLoadInputs: Sendable {
  /// The `--config <path>` flag, if the caller passed one.
  public var configFlag: String?
  /// The process environment (or an injected fake, in tests).
  public var environment: [String: String]
  /// The user's home directory, for `~` expansion and the config-file
  /// fallback path. Injectable so tests never touch the real home directory.
  public var homeDirectory: String
  /// Per-invocation CLI flag overrides, already parsed into a `ConfigValue`
  /// table by the caller (e.g. `.table(["data_root": .string(...)])`) — the
  /// highest-precedence layer.
  public var flags: ConfigValue

  public init(
    configFlag: String? = nil,
    environment: [String: String] = [:],
    homeDirectory: String,
    flags: ConfigValue = .table([:])
  ) {
    self.configFlag = configFlag
    self.environment = environment
    self.homeDirectory = homeDirectory
    self.flags = flags
  }
}

/// The result of a successful ``loadConfig(_:)`` call.
public struct LoadedConfig: Sendable {
  /// The merged, schema-validated, path-expanded config tree.
  public var value: ConfigValue
  /// The config file path that was resolved, whether or not a file actually
  /// existed there — what `--config-path` reports.
  public var configFilePath: String

  public init(value: ConfigValue, configFilePath: String) {
    self.value = value
    self.configFilePath = configFilePath
  }
}

/// Everything that can go wrong loading config, carrying enough structure for a
/// caller to print a precise, non-silent-fallback message and exit non-zero, per
/// `docs/configuration.md`'s validation convention.
public enum ConfigLoadError: Error, Sendable {
  /// The resolved config file exists but couldn't be read (permissions, not a
  /// regular file, encoding, ...).
  case fileReadFailed(path: String, message: String)
  /// The resolved config file exists but isn't valid TOML.
  case tomlParseFailed(path: String, message: String)
  /// The merged config failed schema validation.
  case validation([ConfigError])
}

/// Loads config per the layering model in `docs/configuration.md`: built-in
/// defaults → TOML config file → `EARS_*` environment variables → CLI flags,
/// highest precedence last. Resolves the file path, reads and merges all four
/// layers, validates the result against `schema`, and expands `~`/relative
/// paths in the validated tree.
///
/// `defaults` and `schema` default to ``Phase0ConfigSchema``'s, so existing
/// callers (`ears`, `transcribe`, `cleanup`, `summarize`, and any tool that
/// only needs the shared keys) are unaffected. A tool with its own config
/// slice — e.g. `earsd`, which also needs `[earsd]` — passes its composed
/// pair instead, typically ``EarsdConfigSchema/effectiveDefaults`` and
/// ``EarsdConfigSchema/effectiveSchema`` (or the equivalent for a later
/// phase's subsystem, composed the same way via ``ConfigSchema/union(_:)``).
public func loadConfig(
  _ inputs: ConfigLoadInputs,
  defaults: ConfigValue = Phase0ConfigSchema.defaults,
  schema: ConfigSchema = Phase0ConfigSchema.schema
) -> Result<LoadedConfig, ConfigLoadError> {
  let configFilePath = resolveConfigFilePath(
    configFlag: inputs.configFlag,
    environment: inputs.environment,
    homeDirectory: inputs.homeDirectory
  )

  let fileLayer: ConfigValue
  do {
    fileLayer = try readConfigFileLayer(at: configFilePath)
  } catch let error as TOMLParseError {
    return .failure(.tomlParseFailed(path: configFilePath, message: error.description))
  } catch {
    return .failure(.fileReadFailed(path: configFilePath, message: String(describing: error)))
  }

  let envLayer = configLayer(fromEnvironment: inputs.environment)

  let merged = mergeConfigLayers([
    defaults,
    fileLayer,
    envLayer,
    inputs.flags,
  ])

  let errors = validateConfig(merged, against: schema)
  guard errors.isEmpty else {
    return .failure(.validation(errors))
  }

  let expanded = expandConfigPaths(merged, homeDirectory: inputs.homeDirectory)
  return .success(LoadedConfig(value: expanded, configFilePath: configFilePath))
}

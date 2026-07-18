/// Resolves which TOML config file to read, in the order defined by
/// `docs/configuration.md`: `--config <path>` flag → `EARS_CONFIG` env var →
/// `$XDG_CONFIG_HOME/ears/config.toml` (if set) → `~/.config/ears/config.toml`.
///
/// Takes the environment and home directory as parameters rather than reading
/// `ProcessInfo.processInfo.environment` / `FileManager` directly, so it's a
/// pure, injectable function tests can exercise without touching real process
/// state.
public func resolveConfigFilePath(
  configFlag: String?,
  environment: [String: String],
  homeDirectory: String
) -> String {
  if let configFlag, !configFlag.isEmpty {
    return configFlag
  }
  if let envConfigPath = environment["EARS_CONFIG"], !envConfigPath.isEmpty {
    return envConfigPath
  }
  if let xdgConfigHome = environment["XDG_CONFIG_HOME"], !xdgConfigHome.isEmpty {
    return xdgConfigHome + "/ears/config.toml"
  }
  return homeDirectory + "/.config/ears/config.toml"
}

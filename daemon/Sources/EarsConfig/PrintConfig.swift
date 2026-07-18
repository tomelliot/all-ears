import EarsCore

/// Serializes a merged/validated config tree back to TOML text, for the
/// `--print-config` debugging flag every tool supports (see
/// `docs/configuration.md`'s "Discovery" convention) — shows exactly what the
/// layering resolved to, independent of which layer each value came from.
public func printableConfig(_ config: ConfigValue) -> String {
  TOMLBridge.serialize(config)
}

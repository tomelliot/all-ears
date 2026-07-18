import EarsCore

/// Config file (TOML) I/O and environment-variable resolution, layered on top of
/// `EarsCore`'s pure config-merge logic per the layering model in
/// `docs/configuration.md` (defaults → TOML file → env vars → CLI flags).
public enum EarsConfig {
  /// Version of the `EarsConfig` module.
  public static let version = "0.1.0"
}

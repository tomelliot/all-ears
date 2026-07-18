/// The default control-socket path when `socket_path` is left at its empty
/// "derive it" sentinel (`docs/configuration.md`: `socket_path = ""   # empty
/// => <data_root>/runtime/earsd.sock`).
///
/// Mirrors ``DefaultLogFilePath`` (`EarsLogging`)'s "empty sentinel -> derive
/// from `data_root`" shape, but lives here rather than there since the socket
/// path is a shared `earsd`/`ears` concern, not a logging one: `earsd` binds
/// here, `ears` connects here, and both resolve it from the same loaded
/// config so they always agree without either hard-coding the other's
/// default.
public enum DefaultSocketPath {
  /// - Parameter dataRoot: The resolved `data_root` config value (already
  ///   `~`-expanded).
  public static func resolve(dataRoot: String) -> String {
    let base = dataRoot.hasSuffix("/") ? String(dataRoot.dropLast()) : dataRoot
    return "\(base)/runtime/earsd.sock"
  }
}

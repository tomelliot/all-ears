/// The default JSON Lines log file path for a tool, used when every layer of
/// `docs/logging.md`'s output-sink precedence (`--log-file` flag,
/// `EARS_LOG__FILE`, `[log].file`) leaves it unset: `<data-root>/logs/<tool>.jsonl`.
public enum DefaultLogFilePath {
  /// - Parameters:
  ///   - dataRoot: The resolved `data_root` config value (already `~`-expanded).
  ///   - tool: The emitting binary's name, e.g. `earsd`.
  public static func resolve(dataRoot: String, tool: String) -> String {
    let base = dataRoot.hasSuffix("/") ? String(dataRoot.dropLast()) : dataRoot
    return "\(base)/logs/\(tool).jsonl"
  }
}

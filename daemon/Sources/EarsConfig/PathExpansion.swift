import EarsCore

/// Expands `~` and resolves relative paths in a merged config tree, per
/// `docs/configuration.md`'s path convention: paths support `~` expansion and
/// resolve relative to `data_root` when not absolute — except `data_root` and
/// `output_root` themselves, which only get `~` expansion (they define the base
/// other paths resolve against, so resolving them against themselves would be
/// circular).
///
/// Applies to the Phase 0 path-valued keys: `data_root`, `output_root`,
/// `socket_path`, and `log.file`. An empty path (the "derive it" sentinel for
/// `socket_path`/`log.file`) is left untouched.
///
/// Takes `homeDirectory` as a parameter rather than reading it from the
/// environment, so it's a pure, injectable function tests can exercise without
/// touching the real home directory.
public func expandConfigPaths(_ config: ConfigValue, homeDirectory: String) -> ConfigValue {
  guard case .table(var root) = config else {
    return config
  }

  var dataRoot = ""
  if case .string(let rawDataRoot)? = root["data_root"] {
    dataRoot = expandTilde(rawDataRoot, homeDirectory: homeDirectory)
    root["data_root"] = .string(dataRoot)
  }
  if case .string(let rawOutputRoot)? = root["output_root"] {
    root["output_root"] = .string(expandTilde(rawOutputRoot, homeDirectory: homeDirectory))
  }
  if case .string(let rawSocketPath)? = root["socket_path"] {
    root["socket_path"] = .string(
      resolvePath(rawSocketPath, relativeTo: dataRoot, homeDirectory: homeDirectory)
    )
  }
  if case .table(var log)? = root["log"] {
    if case .string(let rawLogFile)? = log["file"] {
      log["file"] = .string(
        resolvePath(rawLogFile, relativeTo: dataRoot, homeDirectory: homeDirectory))
    }
    root["log"] = .table(log)
  }

  return .table(root)
}

private func expandTilde(_ path: String, homeDirectory: String) -> String {
  guard path == "~" || path.hasPrefix("~/") else { return path }
  guard path != "~" else { return homeDirectory }
  return homeDirectory + path.dropFirst(1)
}

private func resolvePath(_ path: String, relativeTo base: String, homeDirectory: String) -> String {
  guard !path.isEmpty else { return path }

  let expanded = expandTilde(path, homeDirectory: homeDirectory)
  guard !expanded.hasPrefix("/") else { return expanded }
  guard !base.isEmpty else { return expanded }

  return base.hasSuffix("/") ? base + expanded : base + "/" + expanded
}

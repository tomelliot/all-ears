import EarsConfig
import EarsCore
import EarsIPC
import Foundation

/// A resolved-config failure, wrapped so ``ControlClientRuntime`` can return
/// it through `Result`'s `Failure: Error` constraint while staying a plain
/// human-readable message -- there's no richer taxonomy to preserve here.
struct ConfigResolutionError: Error, CustomStringConvertible {
  var description: String
}

/// The plumbing every `ears` subcommand shares: resolve the daemon's control
/// socket from the same layered config every tool reads, connect, and run
/// one request -- kept out of each `ParsableCommand` so those stay thin.
enum ControlClientRuntime {
  /// Resolves `socket_path` from config (the same precedence/defaults
  /// `EarsCLI` and `earsd` use -- `Phase0ConfigSchema`'s shared keys, which
  /// already cover `data_root`/`socket_path`) and connects. On any failure
  /// (bad config, unreachable daemon) this writes a clear message to stderr
  /// and returns `nil`, so a subcommand can exit non-zero without dumping a
  /// raw Swift error.
  static func connect(configFlag: String?) async -> ControlSocketClient? {
    switch resolveSocketPath(configFlag: configFlag) {
    case .failure(let error):
      writeStderr(error.description)
      return nil
    case .success(let path):
      do {
        return try await ControlSocketClient.connect(toPath: path)
      } catch {
        writeStderr(
          "error: could not reach earsd at \(path): \(error). Is the daemon running?")
        return nil
      }
    }
  }

  static func resolveSocketPath(configFlag: String?) -> Result<String, ConfigResolutionError> {
    let environment = ProcessInfo.processInfo.environment
    let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
    let inputs = ConfigLoadInputs(
      configFlag: configFlag, environment: environment, homeDirectory: homeDirectory)
    switch loadConfig(inputs) {
    case .success(let loaded):
      let dataRoot = stringValue(loaded.value, ["data_root"])
      let configured = stringValue(loaded.value, ["socket_path"])
      let path = configured.isEmpty ? DefaultSocketPath.resolve(dataRoot: dataRoot) : configured
      return .success(path)
    case .failure(let error):
      return .failure(ConfigResolutionError(description: describe(error)))
    }
  }

  static func writeStderr(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
  }

  private static func describe(_ error: ConfigLoadError) -> String {
    switch error {
    case .fileReadFailed(let path, let message):
      return "error: could not read config file at \(path): \(message)"
    case .tomlParseFailed(let path, let message):
      return "error: invalid TOML in config file at \(path): \(message)"
    case .validation(let errors):
      let details = errors.map { "  - \($0.message)" }.joined(separator: "\n")
      return "error: invalid config:\n\(details)"
    }
  }

  private static func stringValue(_ config: ConfigValue, _ path: [String]) -> String {
    guard case .string(let value) = walk(config, path) else { return "" }
    return value
  }

  private static func walk(_ config: ConfigValue, _ path: [String]) -> ConfigValue? {
    var current = config
    for key in path {
      guard case .table(let table) = current, let next = table[key] else { return nil }
      current = next
    }
    return current
  }
}

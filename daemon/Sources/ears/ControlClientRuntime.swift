import ArgumentParser
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
  /// What every `hello` from this tool identifies itself as.
  static let clientName = "ears/0.1.0"

  /// Resolves `socket_path` from config (the same precedence/defaults
  /// `EarsCLI` and `earsd` use -- `Phase0ConfigSchema`'s shared keys, which
  /// already cover `data_root`/`socket_path`), connects, and performs the
  /// mandatory `hello` handshake. On any failure (bad config, unreachable
  /// daemon) this writes a clear message to stderr and returns `nil`, so a
  /// subcommand can exit non-zero without dumping a raw Swift error. `debug`
  /// traces each resolution/connection step when `--verbose` is set.
  static func connect(
    configFlag: String?, debug: DebugLog = DebugLog(enabled: false)
  ) async -> ControlSocketClient? {
    debug.log(
      "resolving control socket path (config: \(configFlag ?? "<default search path>"))")
    switch resolveSocketPath(configFlag: configFlag) {
    case .failure(let error):
      writeStderr(error.description)
      return nil
    case .success(let path):
      debug.log("resolved control socket path: \(path)")
      do {
        let client = try await ControlSocketClient.connect(toPath: path)
        // `hello` MUST be the first request on every v2 connection.
        let hello = try await client.hello(client: clientName)
        debug.log(
          "connected to \(hello.daemon) at \(path) "
            + "(boot \(hello.bootID), capabilities: \(hello.capabilities.map(\.rawValue).joined(separator: ",")))"
        )
        return client
      } catch {
        debug.log("connect failed: \(error)")
        writeStderr(
          "error: could not reach earsd at \(path): \(error). Is the daemon running?")
        return nil
      }
    }
  }

  /// `ControlSocketClient.send` plus `--verbose` tracing and uniform wire
  /// error rendering -- the one seam every request/response subcommand
  /// routes through. A ``WireError`` becomes a printed
  /// `error [<code>]: <message>` and a thrown exit code 1.
  static func send<Payload: Codable & Sendable & Hashable>(
    _ call: ControlCall,
    expecting: Payload.Type,
    via client: ControlSocketClient,
    debug: DebugLog
  ) async throws -> Payload {
    debug.log("sending request: \(call.method.rawValue)")
    do {
      let result = try await client.send(call, expecting: Payload.self)
      debug.log("received result: \(debug.json(result))")
      return result
    } catch let error as WireError {
      debug.log("request failed: [\(error.code.rawValue)] \(error.message)")
      writeStderr("error [\(error.code.rawValue)]: \(error.message)")
      throw ExitCode(1)
    } catch {
      debug.log("request failed: \(error)")
      throw error
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

  /// Resolves `data_root` from the same layered config, for the daemon-free
  /// disk reads (`ears meeting list --all`).
  static func resolveDataRoot(configFlag: String?) -> Result<String, ConfigResolutionError> {
    let environment = ProcessInfo.processInfo.environment
    let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
    let inputs = ConfigLoadInputs(
      configFlag: configFlag, environment: environment, homeDirectory: homeDirectory)
    switch loadConfig(inputs) {
    case .success(let loaded):
      let dataRoot = stringValue(loaded.value, ["data_root"])
      return .success(dataRoot.isEmpty ? "." : dataRoot)
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

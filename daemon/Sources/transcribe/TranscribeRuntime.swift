import EarsCLISupport
import EarsConfig
import EarsCore
import Foundation

/// `transcribe`'s real, normal-run (no `--print-config`/`--config-path`)
/// entry point: loads config against the shared `Phase0ConfigSchema` (the
/// same schema `EarsCLI.run` already validated once for the day-one
/// contract -- this is a second, `transcribe`-scoped load, exactly the
/// pattern `EarsdRuntime`'s own doc comment describes and `loadConfig`'s
/// invites), resolves `data_root`/`output_root`/`[transcribe]`'s
/// `backend`/`model`/`compute`, and delegates to ``TranscribePipeline`` for
/// the actual behaviour.
///
/// This is deliberately thin: real environment/home-directory/config-file
/// reads live here and nowhere else, so ``TranscribePipeline`` -- almost
/// all of `transcribe`'s actual logic -- never needs a real environment or
/// config file to be unit tested. Mirrors `earsd`'s
/// `EarsdRuntime`/`DaemonConfigResolution` split.
enum TranscribeRuntime {
  static func run(arguments: EarsCLI.Arguments, inputs: TranscribePipeline.Inputs) async -> Int32 {
    let environment = ProcessInfo.processInfo.environment
    let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
    let flagsLayer = configLayer(
      fromCLIFlags: CLILogFlags(level: arguments.logLevel, file: arguments.logFile))
    let loadInputs = ConfigLoadInputs(
      configFlag: arguments.config,
      environment: environment,
      homeDirectory: homeDirectory,
      flags: flagsLayer
    )

    let loaded: LoadedConfig
    switch loadConfig(loadInputs) {
    case .success(let value): loaded = value
    case .failure(let error):
      writeStderr(describe(error))
      return 1
    }

    let root = loaded.value
    let dataRootPath = stringValue(root, ["data_root"])
    guard !dataRootPath.isEmpty else {
      writeStderr("error: data_root is not configured")
      return 1
    }
    let outputRootPath = stringValue(root, ["output_root"])
    let backendName = stringValue(root, ["transcribe", "backend"], default: "fluidaudio")
    let modelIdentifier = stringValue(root, ["transcribe", "model"])
    let compute = computePreference(
      stringValue(root, ["transcribe", "compute"], default: "automatic"))

    return await TranscribePipeline.run(
      inputs: inputs,
      dataRoot: URL(fileURLWithPath: dataRootPath),
      outputRoot: URL(fileURLWithPath: outputRootPath.isEmpty ? "." : outputRootPath),
      backendName: backendName,
      dependencies: .production(
        loadOptions: LoadOptions(
          modelIdentifier: modelIdentifier.isEmpty ? nil : modelIdentifier,
          compute: compute))
    )
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

  private static func writeStderr(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
  }

  /// Maps `[transcribe].compute`'s documented values (`docs/configuration.md`:
  /// `"ane" | "gpu" | "cpu"`) to the backend-agnostic ``ComputePreference``
  /// FluidAudio's shim (``resolveComputeUnits(for:)``) already understands.
  /// Anything else (including the unset default) is `.automatic`, letting
  /// the backend choose -- never a silent, wrong-but-plausible guess.
  private static func computePreference(_ raw: String) -> ComputePreference {
    switch raw {
    case "ane": return .neuralEngine
    case "gpu": return .gpu
    case "cpu": return .cpu
    default: return .automatic
    }
  }

  // MARK: - Small ConfigValue readers (mirrors EarsCLI's own private helpers)

  private static func stringValue(
    _ config: ConfigValue, _ path: [String], default defaultValue: String = ""
  ) -> String {
    guard case .string(let value) = walk(config, path) else { return defaultValue }
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

import EarsCLISupport
import EarsConfig
import EarsCore
import EarsLLMKit
import Foundation

/// `summarize`'s CLI inputs beyond the shared day-one flags, per
/// `docs/product/specs/llm-stages.md`'s
/// `summarize <transcript.md> [more...] [--preset ...] [--all-presets] [--out] [--model]`.
struct SummarizeCLIInputs: Sendable {
  var transcriptPaths: [String]
  var presetNames: [String]
  var allPresets: Bool
  var out: String?
  var model: String?
}

/// `summarize`'s real, normal-run entry point: loads config against
/// ``LLMStagesConfigSchema``, resolves the LLM backend and the requested
/// `[[summarize.preset]]` entries (reading each preset's `prompt_file`
/// relative to `data_root`), then delegates to ``SummarizePipeline``.
/// Mirrors `cleanup`'s `CleanupRuntime`/`CleanupPipeline` split.
enum SummarizeRuntime {
  static func run(arguments: EarsCLI.Arguments, inputs: SummarizeCLIInputs) async -> Int32 {
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
    switch loadConfig(
      loadInputs,
      defaults: LLMStagesConfigSchema.effectiveDefaults,
      schema: LLMStagesConfigSchema.effectiveSchema
    ) {
    case .success(let value): loaded = value
    case .failure(let error):
      writeStderr(describe(error))
      return 1
    }

    let root = loaded.value
    let dataRootPath = stringValue(root, ["data_root"])
    let dataRoot = URL(fileURLWithPath: dataRootPath.isEmpty ? "." : dataRootPath)

    let backend = stringValue(root, ["llm", "backend"], default: "llm-cli")
    let model = inputs.model ?? stringValue(root, ["llm", "model"])
    let configuredCommand = stringValue(root, ["llm", "command"])
    let command =
      backend == "command" ? configuredCommand : "llm" + (model.isEmpty ? "" : " -m \(model)")
    guard !command.isEmpty else {
      writeStderr("error: no [llm] command resolved (backend=\(backend), model='\(model)')")
      return 1
    }
    let llmBackend = CommandLLMBackend(
      info: LLMBackendInfo(name: backend, model: model.isEmpty ? nil : model), command: command)

    let configuredPresets = presetEntries(root)
    let selected: [ConfigPreset]
    if inputs.allPresets {
      selected = configuredPresets
    } else if !inputs.presetNames.isEmpty {
      selected = configuredPresets.filter { inputs.presetNames.contains($0.name) }
      let missing = Set(inputs.presetNames).subtracting(selected.map(\.name))
      guard missing.isEmpty else {
        writeStderr("error: unknown preset(s): \(missing.sorted().joined(separator: ", "))")
        return 1
      }
    } else {
      writeStderr("error: at least one --preset is required (or pass --all-presets)")
      return 1
    }
    guard !selected.isEmpty else {
      writeStderr("error: no [[summarize.preset]] entries are configured")
      return 1
    }

    let presets = selected.map { preset in
      SummarizePipeline.Preset(
        name: preset.name, promptContent: readPromptFile(preset.promptFile, dataRoot: dataRoot))
    }

    return await SummarizePipeline.run(
      inputs: SummarizePipeline.Inputs(
        transcriptPaths: inputs.transcriptPaths, presets: presets, out: inputs.out),
      dependencies: .production(llmBackend: llmBackend)
    )
  }

  private struct ConfigPreset {
    var name: String
    var promptFile: String
  }

  private static func presetEntries(_ root: ConfigValue) -> [ConfigPreset] {
    guard case .table(let rootTable) = root,
      case .table(let summarizeTable)? = rootTable["summarize"],
      case .array(let entries)? = summarizeTable["preset"]
    else { return [] }
    return entries.compactMap { entry -> ConfigPreset? in
      guard case .table(let fields) = entry,
        case .string(let name)? = fields["name"]
      else { return nil }
      guard case .string(let promptFile)? = fields["prompt_file"] else {
        return ConfigPreset(name: name, promptFile: "")
      }
      return ConfigPreset(name: name, promptFile: promptFile)
    }
  }

  /// An unset/unreadable prompt file yields empty content — a preset with no
  /// prompt still runs (see ``SummarizePipeline/Preset``'s doc comment).
  private static func readPromptFile(_ path: String, dataRoot: URL) -> String {
    guard !path.isEmpty else { return "" }
    let url =
      path.hasPrefix("/") ? URL(fileURLWithPath: path) : dataRoot.appendingPathComponent(path)
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
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

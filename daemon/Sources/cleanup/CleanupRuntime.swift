import EarsCLISupport
import EarsConfig
import EarsCore
import EarsLLMKit
import Foundation

/// `cleanup`'s CLI inputs beyond the shared day-one flags (`--config`,
/// `--log-level`, ...), per `docs/product/specs/llm-stages.md`'s
/// `cleanup <transcript.md> [--out] [--prompt] [--vocab] [--model] [--no-vocab]`.
struct CleanupCLIInputs: Sendable {
  var transcriptPath: String
  var out: String?
  var promptFile: String?
  var vocabPath: String?
  var model: String?
  var useVocab: Bool
}

/// `cleanup`'s real, normal-run entry point: loads config against
/// ``LLMStagesConfigSchema``'s composed schema (giving `[llm]`/`[cleanup]`/
/// `[vocab]` real validation — previously bare passthrough keys), resolves
/// the LLM backend (``EarsLLMKit/CommandLLMBackend``), the cleanup system
/// prompt, and the merged vocabulary list, then delegates to
/// ``CleanupPipeline`` for the actual behaviour. Mirrors `transcribe`'s
/// `TranscribeRuntime`/`TranscribePipeline` split for the same reason: real
/// environment/config-file/vocab-file reads live here and nowhere else.
enum CleanupRuntime {
  static func run(arguments: EarsCLI.Arguments, inputs: CleanupCLIInputs) async -> Int32 {
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
      backend == "command"
      ? configuredCommand
      : "llm" + (model.isEmpty ? "" : " -m \(model)")
    guard !command.isEmpty else {
      writeStderr("error: no [llm] command resolved (backend=\(backend), model='\(model)')")
      return 1
    }
    let llmBackend = CommandLLMBackend(
      info: LLMBackendInfo(name: backend, model: model.isEmpty ? nil : model), command: command)

    let systemPrompt = resolvePromptFile(
      explicit: inputs.promptFile,
      configured: stringValue(root, ["cleanup", "prompt_file"]),
      dataRoot: dataRoot)

    let useVocab = inputs.useVocab && boolValue(root, ["cleanup", "use_vocab"], default: true)
    let vocabulary =
      useVocab
      ? resolveVocabulary(
        globalPath: stringValue(root, ["vocab", "global"]), extraPath: inputs.vocabPath,
        dataRoot: dataRoot) : []

    return await CleanupPipeline.run(
      inputs: CleanupPipeline.Inputs(
        transcriptPath: inputs.transcriptPath,
        out: inputs.out,
        systemPrompt: systemPrompt,
        vocabulary: vocabulary
      ),
      dependencies: .production(llmBackend: llmBackend)
    )
  }

  /// `--prompt <file>` (a literal path, resolved as-given) overrides
  /// `[cleanup].prompt_file` (relative to `data_root`, matching `[vocab]
  /// .global`'s own convention); an unreadable or unset file falls back to
  /// `CleanupPromptBuilder`'s built-in default (`nil` here) rather than
  /// failing the run — a missing custom prompt is a degrade, not a hard stop.
  private static func resolvePromptFile(explicit: String?, configured: String, dataRoot: URL)
    -> String?
  {
    if let explicit, !explicit.isEmpty {
      return try? String(contentsOf: URL(fileURLWithPath: explicit), encoding: .utf8)
    }
    guard !configured.isEmpty else { return nil }
    let url =
      configured.hasPrefix("/")
      ? URL(fileURLWithPath: configured) : dataRoot.appendingPathComponent(configured)
    return try? String(contentsOf: url, encoding: .utf8)
  }

  /// Merges `[vocab].global` (relative to `data_root`) with `--vocab <path>`
  /// (a literal extra list), each parsed via ``VocabFile``. Either file being
  /// absent/unreadable contributes no terms rather than failing the run.
  private static func resolveVocabulary(globalPath: String, extraPath: String?, dataRoot: URL)
    -> [String]
  {
    var terms: [String] = []
    if !globalPath.isEmpty {
      let url =
        globalPath.hasPrefix("/")
        ? URL(fileURLWithPath: globalPath) : dataRoot.appendingPathComponent(globalPath)
      if let content = try? String(contentsOf: url, encoding: .utf8) {
        terms.append(contentsOf: VocabFile.parse(content))
      }
    }
    if let extraPath, !extraPath.isEmpty,
      let content = try? String(contentsOf: URL(fileURLWithPath: extraPath), encoding: .utf8)
    {
      terms.append(contentsOf: VocabFile.parse(content))
    }
    return terms
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

  // MARK: - Small ConfigValue readers (mirrors TranscribeRuntime's own)

  private static func stringValue(
    _ config: ConfigValue, _ path: [String], default defaultValue: String = ""
  ) -> String {
    guard case .string(let value) = walk(config, path) else { return defaultValue }
    return value
  }

  private static func boolValue(_ config: ConfigValue, _ path: [String], default defaultValue: Bool)
    -> Bool
  {
    guard case .bool(let value) = walk(config, path) else { return defaultValue }
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

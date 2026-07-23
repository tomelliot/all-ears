import ArgumentParser
import EarsCLISupport
import Foundation

/// Reads a transcript, applies the LLM with the known-word list and context, and
/// writes a cleaned transcript. See `docs/specs/llm-stages.md`.
///
/// Every invocation runs through `EarsCLI.run(tool:version:arguments:work:)` --
/// the day-one config/logging contract every tool satisfies. The real work is
/// the call's `work` closure, so the final `run.summary` is logged after it
/// completes and reflects its true outcome, never a premature `status=ok`
/// (issue #25). A normal invocation (neither `--print-config` nor
/// `--config-path`) runs ``CleanupRuntime``: it resolves the LLM backend,
/// prompt, and vocabulary from config and the CLI flags below, and cleans
/// `transcript`.
@main
struct Cleanup: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "cleanup"
  )

  // Optional, not required: `--print-config`/`--config-path` must work with
  // no positional argument at all (the day-one contract every tool shares) --
  // its absence is only an error on a normal cleaning run, checked below.
  @Argument(help: "Path to the transcript to clean (a .transcript.md or .clean.md file).")
  var transcript: String?

  @Option(name: .customLong("config"), help: "Path to a TOML config file.")
  var config: String?

  @Flag(
    name: .customLong("print-config"), help: "Print the resolved, merged config as TOML and exit.")
  var printConfig = false

  @Flag(
    name: .customLong("config-path"),
    help: "Print which config file would be loaded (or that none was found) and exit."
  )
  var configPath = false

  @Option(
    name: .customLong("log-level"),
    help: "Override the effective log level (debug|info|notice|error).")
  var logLevel: String?

  @Option(name: .customLong("log-file"), help: "Override the JSON Lines log file path.")
  var logFile: String?

  @Option(name: .customLong("out"), help: "Override the output path for the cleaned transcript.")
  var out: String?

  @Option(name: .customLong("prompt"), help: "Path to a custom cleanup system prompt.")
  var prompt: String?

  @Option(name: .customLong("vocab"), help: "Path to an additional vocabulary list.")
  var vocab: String?

  @Option(name: .customLong("model"), help: "Override the LLM model for this run.")
  var model: String?

  @Flag(name: .customLong("no-vocab"), help: "Disable vocabulary-based correction for this run.")
  var noVocab = false

  func run() async throws {
    let arguments = EarsCLI.Arguments(
      config: config,
      printConfig: printConfig,
      configPath: configPath,
      logLevel: logLevel,
      logFile: logFile
    )

    // Snapshot the flags into locals the `@Sendable` work closure captures.
    let transcript = self.transcript
    let out = self.out
    let prompt = self.prompt
    let vocab = self.vocab
    let model = self.model
    let noVocab = self.noVocab

    // The real run happens inside `work`, between `run.start` and
    // `run.summary`; the summary reflects the outcome we return here, never a
    // premature `status=ok` (issue #25). The `--print-config`/`--config-path`
    // fast paths return before `work` runs.
    let diagnostics = RunDiagnostics()
    let exitCode = await EarsCLI.run(
      tool: "cleanup", version: "0.1.0", arguments: arguments
    ) { _ in
      guard let transcript else {
        let message = "error: a transcript path is required"
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return RunOutcome(exitCode: 1, error: message)
      }
      return await CleanupRuntime.run(
        arguments: arguments,
        inputs: CleanupCLIInputs(
          transcriptPath: transcript,
          out: out,
          promptFile: prompt,
          vocabPath: vocab,
          model: model,
          useVocab: !noVocab
        ),
        diagnostics: diagnostics
      )
    }
    guard exitCode == 0 else { throw ExitCode(exitCode) }
  }
}

import ArgumentParser
import EarsCLISupport
import Foundation

/// Reads one or more transcripts and writes summaries from configured prompts.
/// See `docs/specs/llm-stages.md`.
///
/// Every invocation runs through `EarsCLI.run(tool:version:arguments:work:)` --
/// the day-one config/logging contract every tool satisfies. The real work is
/// the call's `work` closure, so the final `run.summary` is logged after it
/// completes and reflects its true outcome, never a premature `status=ok`
/// (issue #25). A normal invocation (neither `--print-config` nor
/// `--config-path`) runs ``SummarizeRuntime``: it resolves the LLM backend and
/// the requested `[[summarize.preset]]` entries, and summarizes `transcripts`.
@main
struct Summarize: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "summarize"
  )

  // Optional, not required: `--print-config`/`--config-path` must work with
  // no positional arguments at all -- checked as a normal-run requirement
  // below, not enforced by ArgumentParser itself.
  @Argument(help: "Path(s) to the transcript(s) to summarize.")
  var transcripts: [String] = []

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

  @Option(name: .customLong("preset"), help: "Preset(s) to run; repeatable.")
  var preset: [String] = []

  @Flag(name: .customLong("all-presets"), help: "Run every configured preset.")
  var allPresets = false

  @Option(name: .customLong("out"), help: "Override the output path (single-preset runs only).")
  var out: String?

  @Option(name: .customLong("model"), help: "Override the LLM model for this run.")
  var model: String?

  func run() async throws {
    let arguments = EarsCLI.Arguments(
      config: config,
      printConfig: printConfig,
      configPath: configPath,
      logLevel: logLevel,
      logFile: logFile
    )

    // Snapshot the flags into locals the `@Sendable` work closure captures.
    let transcripts = self.transcripts
    let preset = self.preset
    let allPresets = self.allPresets
    let out = self.out
    let model = self.model

    // The real run happens inside `work`, between `run.start` and
    // `run.summary`; the summary reflects the outcome we return here, never a
    // premature `status=ok` (issue #25). The `--print-config`/`--config-path`
    // fast paths return before `work` runs.
    let diagnostics = RunDiagnostics()
    let exitCode = await EarsCLI.run(
      tool: "summarize", version: "0.1.0", arguments: arguments
    ) { _ in
      guard !transcripts.isEmpty else {
        let message = "error: at least one transcript path is required"
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return RunOutcome(exitCode: 1, error: message)
      }
      return await SummarizeRuntime.run(
        arguments: arguments,
        inputs: SummarizeCLIInputs(
          transcriptPaths: transcripts,
          presetNames: preset,
          allPresets: allPresets,
          out: out,
          model: model
        ),
        diagnostics: diagnostics
      )
    }
    guard exitCode == 0 else { throw ExitCode(exitCode) }
  }
}

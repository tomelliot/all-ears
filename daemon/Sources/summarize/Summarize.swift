import ArgumentParser
import EarsCLISupport
import Foundation

/// Reads one or more transcripts and writes summaries from configured prompts.
/// See `docs/product/specs/llm-stages.md`.
///
/// Every invocation still runs `EarsCLI.run(tool:version:arguments:)` first,
/// unchanged -- the day-one config/logging contract every tool satisfies.
/// A normal invocation (neither `--print-config` nor `--config-path`) then
/// runs ``SummarizeRuntime``: it resolves the LLM backend and the requested
/// `[[summarize.preset]]` entries, and summarizes `transcripts`.
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

    let exitCode = await EarsCLI.run(tool: "summarize", version: "0.1.0", arguments: arguments)
    guard exitCode == 0 else { throw ExitCode(exitCode) }
    guard !printConfig, !configPath else { return }

    guard !transcripts.isEmpty else {
      FileHandle.standardError.write(Data("error: at least one transcript path is required\n".utf8))
      throw ExitCode(1)
    }

    let summarizeExitCode = await SummarizeRuntime.run(
      arguments: arguments,
      inputs: SummarizeCLIInputs(
        transcriptPaths: transcripts,
        presetNames: preset,
        allPresets: allPresets,
        out: out,
        model: model
      )
    )
    guard summarizeExitCode == 0 else { throw ExitCode(summarizeExitCode) }
  }
}

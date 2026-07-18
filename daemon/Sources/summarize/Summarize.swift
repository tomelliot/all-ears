import ArgumentParser
import EarsCLISupport

/// Reads one or more transcripts and writes summaries from configured prompts.
/// See `docs/architecture.md`.
///
/// Phase 0 has no LLM backend yet: this stub's entire behavior is the
/// day-one config/logging contract every tool must satisfy — see
/// `EarsCLI.run(tool:version:arguments:)`.
@main
struct Summarize: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "summarize"
  )

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

  func run() async throws {
    let exitCode = await EarsCLI.run(
      tool: "summarize",
      version: "0.1.0",
      arguments: EarsCLI.Arguments(
        config: config,
        printConfig: printConfig,
        configPath: configPath,
        logLevel: logLevel,
        logFile: logFile
      )
    )
    guard exitCode == 0 else { throw ExitCode(exitCode) }
  }
}

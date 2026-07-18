import ArgumentParser
import EarsCLISupport

/// Reads ring-buffer chunks and the VAD index for a source/time-range, runs the
/// ASR model, and writes a transcript to the output location. See
/// `docs/architecture.md`.
///
/// Every invocation still runs `EarsCLI.run(tool:version:arguments:)` first,
/// unchanged -- the day-one config/logging contract every tool satisfies
/// (`--print-config`/`--config-path`, and for a normal run, the `LogSink`
/// bootstrap plus `run.start`/`run.summary` JSON Lines records). A normal
/// invocation (neither flag set) that clears that step then runs
/// ``TranscribeRuntime``: it resolves `--last`/`--source`/`--out` into a
/// requested range and sources, reads each source's real ring-buffer audio,
/// runs the ASR backend, and writes the transcript. See
/// `docs/specs/transcribe.md`.
@main
struct Transcribe: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "transcribe"
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

  @Option(name: .customLong("last"), help: "Range ending now (e.g. 30m, 2h).")
  var last: String?

  @Option(name: .customLong("source"), help: "Source(s) to transcribe; repeatable.")
  var sources: [String] = []

  @Option(name: .customLong("out"), help: "Override the output transcript path.")
  var out: String?

  func run() async throws {
    let arguments = EarsCLI.Arguments(
      config: config,
      printConfig: printConfig,
      configPath: configPath,
      logLevel: logLevel,
      logFile: logFile
    )

    let exitCode = await EarsCLI.run(tool: "transcribe", version: "0.1.0", arguments: arguments)
    guard exitCode == 0 else { throw ExitCode(exitCode) }
    guard !printConfig, !configPath else { return }

    let transcribeExitCode = await TranscribeRuntime.run(
      arguments: arguments,
      inputs: TranscribePipeline.Inputs(last: last, sourceIDs: sources, out: out)
    )
    guard transcribeExitCode == 0 else { throw ExitCode(transcribeExitCode) }
  }
}

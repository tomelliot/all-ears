import ArgumentParser
import EarsCLISupport

/// The always-running capture daemon. Owns every audio source, writes the ring
/// buffer, maintains the VAD index and session records, and exposes the control
/// socket. See `docs/architecture.md`.
///
/// Every invocation still runs `EarsCLI.run(tool:version:arguments:)`
/// first -- the day-one config/logging contract every tool satisfies
/// (`--print-config`/`--config-path`, and for a normal run, the `LogSink`
/// bootstrap plus a `run.start` JSON Lines record). Unlike the one-shot tools,
/// `earsd` passes no `work` closure, so the shared bootstrap logs no
/// `run.summary`: a daemon's run completes at shutdown, not at startup, so
/// ``EarsdRuntime`` logs its own `run.summary` from the `SIGTERM` handler
/// rather than claiming `status=ok` before capture has even started (issue
/// #25). A normal invocation (neither flag set) then runs ``EarsdRuntime``: it
/// loads `earsd`'s own composed config schema, resolves `[[earsd.source]]`
/// into a real `EarsDaemon`, starts it, and keeps the process alive until
/// `SIGTERM`.
@main
struct Earsd: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "earsd"
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
    let arguments = EarsCLI.Arguments(
      config: config,
      printConfig: printConfig,
      configPath: configPath,
      logLevel: logLevel,
      logFile: logFile
    )

    let exitCode = await EarsCLI.run(tool: "earsd", version: "0.1.0", arguments: arguments)
    guard exitCode == 0 else { throw ExitCode(exitCode) }
    guard !printConfig, !configPath else { return }

    let daemonExitCode = await EarsdRuntime.run(arguments: arguments)
    guard daemonExitCode == 0 else { throw ExitCode(daemonExitCode) }
  }
}

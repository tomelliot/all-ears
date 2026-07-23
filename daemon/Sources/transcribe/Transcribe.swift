import ArgumentParser
import EarsCLISupport

/// Reads captured audio chunks and the VAD index for a source/time-range, runs the
/// ASR model, and writes a transcript to the output location. See
/// `docs/architecture.md`.
///
/// Every invocation still runs `EarsCLI.run(tool:version:arguments:)` first,
/// unchanged -- the day-one config/logging contract every tool satisfies
/// (`--print-config`/`--config-path`, and for a normal run, the `LogSink`
/// bootstrap plus `run.start`/`run.summary` JSON Lines records). A normal
/// invocation (neither flag set) that clears that step then runs
/// ``TranscribeRuntime``: it resolves `--last`/`--source`/`--out` into a
/// requested range and sources, reads each source's real captured audio,
/// runs the ASR backend, and writes the transcript. `--follow <source>`
/// instead runs ``FollowRuntime``/``TranscribeFollowPipeline``: attach to a
/// live source and stream finalised segments (stdout + transcript file +
/// the daemon's live feed) until signalled. See `docs/specs/transcribe.md`.
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

  @Option(name: .customLong("from"), help: "Explicit range start (ISO-8601 UTC).")
  var from: String?

  @Option(name: .customLong("to"), help: "Explicit range end (ISO-8601 UTC).")
  var to: String?

  @Option(
    name: .customLong("session"), help: "Resolve range, sources, and vocab from a session id.")
  var session: String?

  @Option(
    name: .customLong("meeting"),
    help: "Union a meeting's transcription intervals into one transcript (meeting id).")
  var meeting: String?

  @Option(name: .customLong("source"), help: "Source(s) to transcribe; repeatable.")
  var sources: [String] = []

  @Option(
    name: .customLong("file"),
    help:
      "Transcribe a standalone audio file (e.g. a .m4a) directly, bypassing the capture store; repeatable, one transcript written per file."
  )
  var files: [String] = []

  @Option(name: .customLong("out"), help: "Override the output transcript path.")
  var out: String?

  @Option(
    name: .customLong("follow"),
    help: "Attach to a live source by id and stream finalised segments until signalled.")
  var follow: String?

  @Flag(
    name: .customLong("json"),
    help: "(follow) Emit JSON segment lines to stdout instead of plain text.")
  var json = false

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

    if !files.isEmpty {
      // `--file` is a standalone-file batch: every range/source/session
      // selector and the live-`--follow` attach make no sense against a file
      // with no index and no wall-clock time, so mixing them is a precise
      // error rather than a silent ignore (matching `--follow`/`--meeting`).
      guard follow == nil, last == nil, from == nil, to == nil, session == nil, meeting == nil,
        sources.isEmpty, !json
      else {
        throw ValidationError(
          "--file cannot be combined with "
            + "--follow/--last/--from/--to/--session/--meeting/--source/--json")
      }
      let filesExitCode = await TranscribeRuntime.runFiles(
        arguments: arguments,
        inputs: TranscribeFilePipeline.Inputs(files: files, out: out))
      guard filesExitCode == 0 else { throw ExitCode(filesExitCode) }
      return
    }

    if let follow {
      // Follow is attach-and-tail; batch is resolve-a-range-and-exit. The
      // flags that shape a batch range make no sense here, so mixing them
      // is a precise error rather than a silent ignore.
      guard last == nil, from == nil, to == nil, session == nil, meeting == nil, sources.isEmpty
      else {
        throw ValidationError(
          "--follow cannot be combined with --last/--from/--to/--session/--meeting/--source")
      }
      let followExitCode = await FollowRuntime.run(
        arguments: arguments,
        inputs: TranscribeFollowPipeline.Inputs(source: follow, json: json, out: out)
      )
      guard followExitCode == 0 else { throw ExitCode(followExitCode) }
      return
    }
    guard !json else {
      throw ValidationError("--json is only meaningful with --follow")
    }
    if meeting != nil {
      // A meeting names its own range and sources; mixing selectors is a
      // precise error rather than a silent ignore.
      guard last == nil, from == nil, to == nil, session == nil, sources.isEmpty else {
        throw ValidationError(
          "--meeting cannot be combined with --last/--from/--to/--session/--source")
      }
    }

    let transcribeExitCode = await TranscribeRuntime.run(
      arguments: arguments,
      inputs: TranscribePipeline.Inputs(
        last: last, from: from, to: to, session: session, meeting: meeting, sourceIDs: sources,
        out: out)
    )
    guard transcribeExitCode == 0 else { throw ExitCode(transcribeExitCode) }
  }
}

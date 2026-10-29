import ArgumentParser
import EarsCLISupport
import EarsCore
import EarsDataStore
import EarsIPC
import Foundation

/// Control client for `earsd`: the session-first status/sessions surfaces,
/// session lifecycle, and the live event feed, over the v2 control socket.
/// See `docs/specs/control-protocol.md`.
///
/// The root declares no flags of its own, so no root option can collide with
/// a subcommand's; bare `ears` runs `status` (the dashboard). Phase 0's
/// day-one config-discovery contract lives on the `config` subcommand. Each
/// subcommand below is a thin `ClientOptions`-driven wrapper around
/// ``ControlClientRuntime``/``OutputFormatting``, so none of them duplicate
/// socket-connection or output-formatting logic.
@main
struct Ears: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "ears",
    abstract: "Control client for the earsd capture daemon.",
    subcommands: [
      ConfigCommand.self, StatusCommand.self, SessionsCommand.self, SourcesCommand.self,
      CaptureCommand.self,
      SessionCommand.self, WatchCommand.self,
      FlushCommand.self,
    ],
    defaultSubcommand: StatusCommand.self
  )
}

/// The one declaration site for `--config` in this tool. Every subcommand
/// that needs it composes this via `@OptionGroup` — directly, or through
/// ``ClientOptions`` — so the flag is never redeclared with the same
/// string in two places.
struct ConfigOptions: ParsableArguments {
  @Option(name: .customLong("config"), help: "Path to a TOML config file.")
  var config: String?
}

/// Options every daemon-facing subcommand shares: which config to resolve
/// the socket path from (via ``ConfigOptions``), whether to emit raw JSON
/// instead of a human-readable summary, and whether to trace the
/// client↔daemon exchange.
struct ClientOptions: ParsableArguments {
  @OptionGroup var configOptions: ConfigOptions

  @Flag(name: .customLong("json"), help: "Emit raw JSON instead of human-readable output.")
  var json = false

  @Flag(
    name: [.customShort("v"), .customLong("verbose")],
    help: "Trace socket resolution, requests, and replies to stderr (see DebugLog).")
  var verbose = false

  var config: String? { configOptions.config }

  /// The subcommand's ``DebugLog``, built from `--verbose`.
  var debug: DebugLog { DebugLog(enabled: verbose) }
}

/// The connect → send → emit sequence every simple request/response
/// subcommand shares.
private func runSimpleCommand<Payload: Codable & Sendable & Hashable>(
  _ call: ControlCall,
  expecting: Payload.Type,
  options: ClientOptions,
  humanSuccess: (Payload) -> String
) async throws {
  let debug = options.debug
  guard let client = await ControlClientRuntime.connect(configFlag: options.config, debug: debug)
  else {
    throw ExitCode(1)
  }
  let result = try await ControlClientRuntime.send(
    call, expecting: Payload.self, via: client, debug: debug)
  await client.close()
  let code = OutputFormatting.emit(result, json: options.json, humanSuccess: humanSuccess)
  if code != 0 { throw ExitCode(code) }
}

// MARK: - config show / path

struct ConfigCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "config",
    abstract: "Inspect config discovery and the resolved, merged config.",
    subcommands: [ConfigShowCommand.self, ConfigPathCommand.self, ConfigDescribeCommand.self]
  )
}

struct ConfigDescribeCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "describe",
    abstract:
      "List every config setting across all tools with its type, default, and description.")

  func run() async throws {
    // A static reference rendered from the schema itself — every tool's slice
    // composed into one listing — so a user can discover which keys exist,
    // what they mean, and their defaults without reading the source or the
    // docs. The current resolved value of each key is `ears config show`'s job;
    // this answers "what can I set, and to what?", including via `--set`.
    print(describeConfig(schema: FullConfigSchema.schema, defaults: FullConfigSchema.defaults))
  }
}

struct ConfigShowCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "show",
    abstract: "Print the resolved, merged config as TOML.")

  @OptionGroup var options: ConfigOptions

  @Option(
    name: .customLong("log-level"),
    help: "Override the effective log level (debug|info|notice|error).")
  var logLevel: String?

  @Option(name: .customLong("log-file"), help: "Override the JSON Lines log file path.")
  var logFile: String?

  func run() async throws {
    let exitCode = await EarsCLI.run(
      tool: "ears",
      version: "0.1.0",
      arguments: EarsCLI.Arguments(
        config: options.config,
        printConfig: true,
        logLevel: logLevel,
        logFile: logFile
      )
    )
    guard exitCode == 0 else { throw ExitCode(exitCode) }
  }
}

struct ConfigPathCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "path",
    abstract: "Print which config file would be loaded (or that none was found).")

  @OptionGroup var options: ConfigOptions

  func run() async throws {
    let exitCode = await EarsCLI.run(
      tool: "ears",
      version: "0.1.0",
      arguments: EarsCLI.Arguments(config: options.config, configPath: true)
    )
    guard exitCode == 0 else { throw ExitCode(exitCode) }
  }
}

// MARK: - status

struct StatusCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "status",
    abstract:
      "The daemon dashboard: live sessions with their sources, and recent pipeline outcomes.")

  @OptionGroup var options: ClientOptions

  func run() async throws {
    let debug = options.debug
    guard let client = await ControlClientRuntime.connect(configFlag: options.config, debug: debug)
    else {
      throw ExitCode(1)
    }
    let status = try await ControlClientRuntime.send(
      .status, expecting: StatusData.self, via: client, debug: debug)
    await client.close()
    if options.json {
      // The machine surface keeps its existing payload shape untouched
      // (additive keys only — pinned by CLISmokeTests).
      let code = OutputFormatting.emit(status, json: true, humanSuccess: { _ in "" })
      if code != 0 { throw ExitCode(code) }
      return
    }
    print(
      StatusDashboardAssembly.dashboard(status: status, configFlag: options.config, debug: debug))
  }
}

// MARK: - sessions (top-level list with pipeline outcomes)

struct SessionsCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "sessions",
    abstract: "Recent sessions, one line each, with their pipeline outcome.")

  @OptionGroup var options: ClientOptions

  @Flag(
    name: .customLong("all"),
    help: "Read every sessions/*/session.toml from the data root, daemon-free.")
  var all = false

  func run() async throws {
    try await runSessionsList(options: options, all: all)
  }
}

/// The one implementation behind `ears sessions` and its compatibility alias
/// `ears session list`: live + recent sessions from the daemon, or (`--all`)
/// full history from disk. `--json` keeps the `session.list` payload shape
/// exactly; the human view renders pipeline outcomes from a disk scan.
private func runSessionsList(options: ClientOptions, all: Bool) async throws {
  let sessions: [Session]
  if all {
    // Closed history is read from disk, not the socket — works with no
    // daemon running at all.
    let dataRoot: String
    switch ControlClientRuntime.resolveDataRoot(configFlag: options.config) {
    case .failure(let error):
      ControlClientRuntime.writeStderr(error.description)
      throw ExitCode(1)
    case .success(let root):
      dataRoot = root
    }
    sessions = SessionStore.readAll(dataRoot: URL(fileURLWithPath: dataRoot))
      .sorted { $0.started < $1.started }
  } else {
    let debug = options.debug
    guard let client = await ControlClientRuntime.connect(configFlag: options.config, debug: debug)
    else {
      throw ExitCode(1)
    }
    let data = try await ControlClientRuntime.send(
      .sessionList, expecting: SessionListData.self, via: client, debug: debug)
    await client.close()
    sessions = data.sessions
  }

  if options.json {
    let code = OutputFormatting.emit(
      SessionListData(sessions: sessions), json: true, humanSuccess: { _ in "" })
    if code != 0 { throw ExitCode(code) }
    return
  }

  // The outcome column comes from disk; an unresolvable scan environment
  // degrades to record-only outcomes rather than failing the list.
  let entries: [SessionListEntry]
  let emptiness: TranscriptEmptinessPolicy
  switch SessionArtifactScanner.environment(configFlag: options.config) {
  case .failure:
    entries = sessions.map { SessionListEntry(session: $0, artifacts: SessionArtifacts()) }
    emptiness = .defaults
  case .success(let environment):
    entries = sessions.map {
      SessionListEntry(
        session: $0, artifacts: SessionArtifactScanner.scan(session: $0, environment: environment))
    }
    emptiness = environment.emptiness
  }
  let now = Instant(secondsSinceEpoch: Date().timeIntervalSince1970)
  print(
    SessionsListRendering.render(
      entries: entries, now: now, timeZone: TimeZone.current, emptiness: emptiness))
}

// MARK: - sources list / enable / disable

struct SourcesCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "sources",
    subcommands: [
      SourcesListCommand.self, SourcesAddCommand.self, SourcesRemoveCommand.self,
      SourcesEnableCommand.self, SourcesDisableCommand.self,
    ]
  )
}

struct SourcesListCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list", abstract: "All configured sources and state.")

  @OptionGroup var options: ClientOptions

  func run() async throws {
    try await runSimpleCommand(
      .sourcesList, expecting: SourcesListData.self, options: options,
      humanSuccess: OutputFormatting.humanSourcesList)
  }
}

struct SourcesAddCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "add",
    abstract:
      "Add a source at runtime (currently rejected: Phase 4 seam, see docs/specs/capture-daemon.md)."
  )

  @OptionGroup var options: ClientOptions
  @Argument(help: "Source id, e.g. app:us.zoom.xos.") var source: String

  @Option(name: .customLong("class"), help: "Source class: mic|system|app|browser|device.")
  var sourceClass: String

  @Option(name: .customLong("label"), help: "Human-readable label.") var label: String?
  @Option(name: .customLong("device-uid"), help: "Core Audio device UID.") var deviceUID: String?
  @Option(name: .customLong("native-sample-rate"), help: "Native capture sample rate, in Hz.")
  var nativeSampleRate: Int?
  @Option(name: .customLong("asr-sample-rate"), help: "ASR-rate sample rate, in Hz.")
  var asrSampleRate: Int?
  @Flag(name: .customLong("store-native"), help: "Also store the native-rate chunk stream.")
  var storeNative = false
  @Option(name: .customLong("channels"), help: "Channel count.") var channels: Int?
  @Option(name: .customLong("codec"), help: "Chunk codec, e.g. aac.") var codec: String?
  @Option(name: .customLong("bitrate"), help: "Chunk encoder bitrate.") var bitrate: Int?

  func run() async throws {
    guard let sourceClass = SourceClass(rawValue: sourceClass) else {
      ControlClientRuntime.writeStderr(
        "error: '\(sourceClass)' is not a recognised source class "
          + "(expected one of: \(SourceClass.allCases.map(\.rawValue).joined(separator: ", ")))")
      throw ExitCode(1)
    }
    let spec = SourceSpec(
      id: SourceID(source),
      sourceClass: sourceClass,
      label: label,
      deviceUID: deviceUID,
      nativeSampleRate: nativeSampleRate,
      asrSampleRate: asrSampleRate,
      storeNative: storeNative ? true : nil,
      channels: channels,
      codec: codec,
      bitrate: bitrate
    )
    try await runSimpleCommand(
      .sourcesAdd(spec), expecting: EmptyData.self, options: options,
      humanSuccess: OutputFormatting.humanEmpty)
  }
}

struct SourcesRemoveCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "remove", abstract: "Remove a source at runtime.")

  @OptionGroup var options: ClientOptions
  @Argument(help: "Source id, e.g. mic.") var source: String

  func run() async throws {
    try await runSimpleCommand(
      .sourcesRemove(source: SourceID(source)), expecting: EmptyData.self, options: options,
      humanSuccess: OutputFormatting.humanEmpty)
  }
}

struct SourcesEnableCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "enable", abstract: "Start capturing a source.")

  @OptionGroup var options: ClientOptions
  @Argument(help: "Source id, e.g. mic.") var source: String

  func run() async throws {
    try await runSimpleCommand(
      .sourcesEnable(source: SourceID(source)), expecting: EmptyData.self, options: options,
      humanSuccess: OutputFormatting.humanEmpty)
  }
}

struct SourcesDisableCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "disable", abstract: "Stop capturing a source.")

  @OptionGroup var options: ClientOptions
  @Argument(help: "Source id, e.g. mic.") var source: String

  func run() async throws {
    try await runSimpleCommand(
      .sourcesDisable(source: SourceID(source)), expecting: EmptyData.self, options: options,
      humanSuccess: OutputFormatting.humanEmpty)
  }
}

// MARK: - capture pause / resume

struct CaptureCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "capture",
    subcommands: [CapturePauseCommand.self, CaptureResumeCommand.self]
  )
}

struct CapturePauseCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "pause",
    abstract: "Pause a source, or every source when omitted (records a gap).")

  @OptionGroup var options: ClientOptions
  @Argument(help: "Source id, e.g. mic. Omit to pause every source.") var source: String?

  func run() async throws {
    try await runSimpleCommand(
      .capturePause(source: source.map { SourceID($0) }), expecting: EmptyData.self,
      options: options, humanSuccess: OutputFormatting.humanEmpty)
  }
}

struct CaptureResumeCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "resume", abstract: "Resume a source, or every source when omitted.")

  @OptionGroup var options: ClientOptions
  @Argument(help: "Source id, e.g. mic. Omit to resume every source.") var source: String?

  func run() async throws {
    try await runSimpleCommand(
      .captureResume(source: source.map { SourceID($0) }), expecting: EmptyData.self,
      options: options, humanSuccess: OutputFormatting.humanEmpty)
  }
}

// MARK: - session start / end / pause / resume / rename / list

/// The daemon-owned session lifecycle, from any frontend — manual sessions
/// give CLI recordings the same naming, pause-as-marks, and roster powers as
/// browser calls (`docs/specs/control-protocol.md`'s "Session").
struct SessionCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "session",
    abstract: "Daemon-owned session lifecycle: show, start, end, pause/resume marks, rename, list.",
    subcommands: [
      SessionShowCommand.self, SessionStartCommand.self, SessionEndCommand.self,
      SessionPauseCommand.self,
      SessionResumeCommand.self, SessionRenameCommand.self, SessionListCommand.self,
      SessionRetryCommand.self,
    ]
  )
}

struct SessionStartCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "start",
    abstract: "Start a session (manual unless --platform/--external-id name an identity).")

  @OptionGroup var options: ClientOptions
  @Option(name: .customLong("title"), help: "Session title.") var title: String?
  @Option(name: .customLong("source"), help: "Source id; repeatable.") var sources: [String] = []
  @Option(name: .customLong("platform"), help: "Platform of an external identity, e.g. meet.")
  var platform: String?
  @Option(
    name: .customLong("external-id"),
    help: "The platform's own session id (idempotent with --platform).")
  var externalID: String?

  func run() async throws {
    let params = SessionStartParams(
      platform: platform, externalID: externalID, title: title,
      sources: sources.map { SourceID($0) })
    try await runSimpleCommand(
      .sessionStart(params), expecting: Session.self, options: options,
      humanSuccess: OutputFormatting.humanSession)
  }
}

struct SessionEndCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "end",
    abstract: "End a session: closes the open mark and finalizes the session.")

  @OptionGroup var options: ClientOptions
  @Argument(help: "Session id.") var session: String

  func run() async throws {
    try await runSimpleCommand(
      .sessionEnd(session: session), expecting: Session.self, options: options,
      humanSuccess: OutputFormatting.humanSession)
  }
}

struct SessionPauseCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "pause",
    abstract: "Pause a session's transcription mark (capture is untouched).")

  @OptionGroup var options: ClientOptions
  @Argument(help: "Session id.") var session: String

  func run() async throws {
    try await runSimpleCommand(
      .sessionPause(session: session), expecting: Session.self, options: options,
      humanSuccess: OutputFormatting.humanSession)
  }
}

struct SessionResumeCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "resume", abstract: "Resume a paused session (opens a new mark).")

  @OptionGroup var options: ClientOptions
  @Argument(help: "Session id.") var session: String

  func run() async throws {
    try await runSimpleCommand(
      .sessionResume(session: session), expecting: Session.self, options: options,
      humanSuccess: OutputFormatting.humanSession)
  }
}

struct SessionRenameCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "rename", abstract: "Rename a session.")

  @OptionGroup var options: ClientOptions
  @Argument(help: "Session id.") var session: String
  @Option(name: .customLong("title"), help: "The new title.") var title: String
  @Option(
    name: .customLong("if-rev"),
    help: "Compare-and-set: fail with 'conflict' unless the session is at this revision.")
  var ifRev: Int?

  func run() async throws {
    try await runSimpleCommand(
      .sessionRename(SessionRenameParams(session: session, title: title, ifRev: ifRev)),
      expecting: Session.self, options: options,
      humanSuccess: OutputFormatting.humanSession)
  }
}

struct SessionListCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list",
    abstract: "Alias of `ears sessions`: live + recent sessions; --all reads history from disk.")

  @OptionGroup var options: ClientOptions

  @Flag(
    name: .customLong("all"),
    help: "Read every sessions/*/session.toml from the data root, daemon-free.")
  var all = false

  func run() async throws {
    try await runSessionsList(options: options, all: all)
  }
}

struct SessionShowCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "show",
    abstract: "One session's pipeline state, stage by stage, reconstructed from disk.")

  @OptionGroup var options: ClientOptions

  @Argument(
    help: "A unique session-id prefix, a title fragment, or a start time HH:MM (today).")
  var ref: String

  @Flag(name: .customLong("warnings"), help: "Print the session's warnings verbatim.")
  var warnings = false

  func run() async throws {
    let environment = try loadScanEnvironment(options)
    let now = Instant(secondsSinceEpoch: Date().timeIntervalSince1970)
    let timeZone = TimeZone.current
    let session = try resolveSession(ref, environment: environment, now: now, timeZone: timeZone)
    try printPipeline(
      session, environment: environment, now: now, timeZone: timeZone, json: options.json,
      showWarnings: warnings)
  }
}

struct SessionRetryCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "retry",
    abstract: "Rerun an ended session's pipeline from the stage that did not finish.",
    discussion: """
      The daemon runs the stages and the command waits for them, then prints the \
      pipeline view. A failed cleanup or summarize reruns from that stage, \
      reusing the transcript on disk.
      """)

  @OptionGroup var options: ClientOptions

  @Argument(
    help: "A unique session-id prefix, a title fragment, or a start time HH:MM (today).")
  var ref: String

  @Option(
    name: .customLong("from"),
    help: "Rerun from this stage (transcribe, cleanup, summarize), not the first unfinished one.")
  var from: String?

  func run() async throws {
    let environment = try loadScanEnvironment(options)
    let now = Instant(secondsSinceEpoch: Date().timeIntervalSince1970)
    let timeZone = TimeZone.current
    let session = try resolveSession(ref, environment: environment, now: now, timeZone: timeZone)
    let artifacts = SessionArtifactScanner.scan(session: session, environment: environment)

    let stage: String
    if let from {
      stage = from
    } else {
      let stages = SessionPipeline.stages(
        session: session, artifacts: artifacts, now: now, emptiness: environment.emptiness)
      switch SessionPipeline.retryStart(stages) {
      case .from(let name):
        stage = name
      case .nothingToRetry:
        ControlClientRuntime.writeStderr(
          "error: every stage of '\(session.title)' finished; "
            + "pass --from <stage> to rerun one anyway")
        throw ExitCode(1)
      case .emptyTranscript:
        ControlClientRuntime.writeStderr(
          "error: '\(session.title)' was not summarized because its transcript is empty; "
            + "pass --from cleanup to summarize it anyway")
        throw ExitCode(1)
      case .live:
        ControlClientRuntime.writeStderr(
          "error: '\(session.title)' has not ended; its pipeline runs when it does")
        throw ExitCode(1)
      }
    }

    let input: String?
    switch stage {
    case "cleanup":
      input = artifacts.transcriptPath
    case "summarize":
      guard artifacts.cleanupExists, let cleanupPath = artifacts.cleanupPath else {
        ControlClientRuntime.writeStderr(
          "error: no cleaned transcript for '\(session.title)'; retry from cleanup instead")
        throw ExitCode(1)
      }
      input = cleanupPath
    default:
      input = nil
    }

    let debug = options.debug
    guard let client = await ControlClientRuntime.connect(configFlag: options.config, debug: debug)
    else {
      throw ExitCode(1)
    }
    ControlClientRuntime.writeStderr("retrying '\(session.title)' from \(stage)…")
    let retried = try await ControlClientRuntime.send(
      .sessionRetry(SessionRetryParams(session: session.id, from: stage, input: input)),
      expecting: Session.self, via: client, debug: debug)
    await client.close()

    try printPipeline(
      retried, environment: environment,
      now: Instant(secondsSinceEpoch: Date().timeIntervalSince1970), timeZone: timeZone,
      json: options.json, showWarnings: false)
    if retried.pipelineIssues.contains(where: { $0.kind == .failed }) {
      throw ExitCode(1)
    }
  }
}

/// The scan environment `session show` and `session retry` read, or exit 1
/// with the config error.
private func loadScanEnvironment(_ options: ClientOptions) throws -> ScanEnvironment {
  switch SessionArtifactScanner.environment(configFlag: options.config) {
  case .failure(let error):
    ControlClientRuntime.writeStderr(error.description)
    throw ExitCode(1)
  case .success(let resolved):
    return resolved
  }
}

/// The one session `ref` names, read from disk; exits 1 with a hint when it
/// names none or several.
private func resolveSession(
  _ ref: String, environment: ScanEnvironment, now: Instant, timeZone: TimeZone
) throws -> Session {
  let sessions = SessionStore.readAll(dataRoot: environment.dataRoot)
  switch SessionRef.resolve(ref, in: sessions, now: now, timeZone: timeZone) {
  case .notFound:
    ControlClientRuntime.writeStderr(
      "error: no session matches '\(ref)' — try a unique id prefix, a title fragment, "
        + "or a start time HH:MM (today); `ears sessions --all` lists them")
    throw ExitCode(1)
  case .ambiguous(let candidates):
    var lines = ["error: '\(ref)' matches \(candidates.count) sessions:"]
    for candidate in candidates {
      let day = HumanUnits.localDate(candidate.started, timeZone: timeZone)
      let clock = HumanUnits.clock(candidate.started, timeZone: timeZone)
      lines.append("  \(candidate.id.prefix(8))  \(day) \(clock)  \(candidate.title)")
    }
    lines.append("narrow it: a longer id prefix, or a more specific title fragment")
    ControlClientRuntime.writeStderr(lines.joined(separator: "\n"))
    throw ExitCode(1)
  case .match(let session):
    return session
  }
}

/// Prints one session's pipeline view, scanned fresh from disk.
private func printPipeline(
  _ session: Session, environment: ScanEnvironment, now: Instant, timeZone: TimeZone,
  json: Bool, showWarnings: Bool
) throws {
  let artifacts = SessionArtifactScanner.scan(session: session, environment: environment)
  if json {
    let view = SessionShowView.build(
      session: session, artifacts: artifacts, now: now, emptiness: environment.emptiness)
    let code = OutputFormatting.emit(view, json: true, humanSuccess: { _ in "" })
    if code != 0 { throw ExitCode(code) }
    return
  }
  print(
    SessionShowRendering.render(
      session: session, artifacts: artifacts, now: now, timeZone: timeZone,
      showWarnings: showWarnings, emptiness: environment.emptiness))
}

// MARK: - watch

struct WatchCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "watch", abstract: "Subscribe and print the snapshot, then the live feed.")

  @OptionGroup var options: ClientOptions
  @Option(
    name: .customLong("events"),
    help: "Telemetry kinds to receive (vad,segment,job); state events are always delivered.")
  var events: String = ""
  @Option(name: .customLong("source"), help: "Source id filter; repeatable. Omit for all sources.")
  var sources: [String] = []

  /// Runs until the daemon closes the connection or the process is
  /// interrupted (Ctrl-C) — `watch` is read-only, so the default SIGINT
  /// disposition is a clean-enough exit.
  func run() async throws {
    let debug = options.debug
    guard let client = await ControlClientRuntime.connect(configFlag: options.config, debug: debug)
    else {
      throw ExitCode(1)
    }
    let tokens = events.split(separator: ",").map(String.init)
    let kinds = tokens.compactMap { EventKind(rawValue: $0) }
    let unrecognized = tokens.filter { EventKind(rawValue: $0) == nil }
    if !unrecognized.isEmpty {
      debug.log(
        "ignoring unrecognized event kind(s): \(unrecognized.joined(separator: ", ")) "
          + "(known: \(EventKind.allCases.map(\.rawValue).joined(separator: ",")))")
    }
    let params = SubscribeParams(events: kinds, sources: sources.map { SourceID($0) })

    let snapshot: SnapshotData
    let stream: AsyncStream<EventFrame>
    do {
      (snapshot, stream) = try await client.subscribe(params)
    } catch {
      debug.log("subscribe failed: \(error)")
      ControlClientRuntime.writeStderr("error: could not subscribe: \(error)")
      throw ExitCode(1)
    }

    let encoder = JSONEncoder()
    if options.json {
      if let data = try? encoder.encode(snapshot), let line = String(data: data, encoding: .utf8) {
        print(line)
      }
    } else {
      print("snapshot rev=\(snapshot.rev)")
      print(OutputFormatting.humanSessions(snapshot.sessions))
      print(OutputFormatting.humanSourcesList(SourcesListData(sources: snapshot.sources)))
    }

    var eventCount = 0
    for await frame in stream {
      eventCount += 1
      if options.json {
        if let data = try? encoder.encode(frame), let line = String(data: data, encoding: .utf8) {
          print(line)
        }
      } else {
        print(OutputFormatting.humanEvent(frame))
      }
    }
    // Reaching here means the daemon (not Ctrl-C) ended the stream.
    debug.log("event stream closed by daemon after \(eventCount) event(s)")
  }
}

// MARK: - flush

struct FlushCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "flush",
    abstract: "Force-flush in-flight chunks and the index for every enabled source.")

  @OptionGroup var options: ClientOptions

  func run() async throws {
    try await runSimpleCommand(
      .flush, expecting: EmptyData.self, options: options,
      humanSuccess: OutputFormatting.humanEmpty)
  }
}

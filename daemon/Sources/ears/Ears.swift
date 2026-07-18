import ArgumentParser
import EarsCLISupport
import EarsCore
import EarsIPC
import Foundation

/// Control client for `earsd`: source status, session lifecycle, and the
/// live event feed, over the control socket. See
/// `docs/specs/capture-daemon.md`'s "`ears` — control client" section.
///
/// The root is a pure dispatcher — it declares no flags of its own, so no
/// root option can collide with a subcommand's. Phase 0's day-one
/// config-discovery contract (per `docs/configuration.md` and
/// `EarsCLI.run`) lives on the `config` subcommand: `ears config show` /
/// `ears config path`, where the single-flag tools spell it
/// `--print-config` / `--config-path`. Each real subcommand below is a
/// thin `ClientOptions`-driven wrapper around
/// ``ControlClientRuntime``/``OutputFormatting``, so none of them duplicate
/// socket-connection or output-formatting logic.
@main
struct Ears: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "ears",
    abstract: "Control client for the earsd capture daemon.",
    subcommands: [
      ConfigCommand.self, StatusCommand.self, SourcesCommand.self, SessionCommand.self,
      MarkCommand.self, WatchCommand.self,
    ]
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
/// the socket path from (via ``ConfigOptions``), and whether to emit raw
/// JSON instead of a human-readable summary. `--json` per
/// `docs/specs/capture-daemon.md`: "Output is human-readable by default,
/// `--json` for scripting."
struct ClientOptions: ParsableArguments {
  @OptionGroup var configOptions: ConfigOptions

  @Flag(name: .customLong("json"), help: "Emit raw JSON instead of human-readable output.")
  var json = false

  var config: String? { configOptions.config }
}

// MARK: - config show / path

struct ConfigCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "config",
    abstract: "Inspect config discovery and the resolved, merged config.",
    subcommands: [ConfigShowCommand.self, ConfigPathCommand.self]
  )
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
    abstract: "Daemon + per-source state, buffer occupancy, active sessions.")

  @OptionGroup var options: ClientOptions

  func run() async throws {
    guard let client = await ControlClientRuntime.connect(configFlag: options.config) else {
      throw ExitCode(1)
    }
    let response = try await client.send(.status, expecting: StatusData.self)
    await client.close()
    let code = OutputFormatting.emit(
      response, json: options.json, humanSuccess: OutputFormatting.humanStatus)
    if code != 0 { throw ExitCode(code) }
  }
}

// MARK: - sources list / enable / disable

struct SourcesCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "sources",
    subcommands: [SourcesListCommand.self, SourcesEnableCommand.self, SourcesDisableCommand.self]
  )
}

struct SourcesListCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list", abstract: "All configured sources and state.")

  @OptionGroup var options: ClientOptions

  func run() async throws {
    guard let client = await ControlClientRuntime.connect(configFlag: options.config) else {
      throw ExitCode(1)
    }
    let response = try await client.send(.sourcesList, expecting: SourcesListData.self)
    await client.close()
    let code = OutputFormatting.emit(
      response, json: options.json, humanSuccess: OutputFormatting.humanSourcesList)
    if code != 0 { throw ExitCode(code) }
  }
}

struct SourcesEnableCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "enable", abstract: "Start capturing a source.")

  @OptionGroup var options: ClientOptions
  @Argument(help: "Source id, e.g. mic.") var source: String

  func run() async throws {
    guard let client = await ControlClientRuntime.connect(configFlag: options.config) else {
      throw ExitCode(1)
    }
    let response = try await client.send(
      .sourcesEnable(source: SourceID(source)), expecting: EmptyData.self)
    await client.close()
    let code = OutputFormatting.emit(
      response, json: options.json, humanSuccess: OutputFormatting.humanEmpty)
    if code != 0 { throw ExitCode(code) }
  }
}

struct SourcesDisableCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "disable", abstract: "Stop capturing a source.")

  @OptionGroup var options: ClientOptions
  @Argument(help: "Source id, e.g. mic.") var source: String

  func run() async throws {
    guard let client = await ControlClientRuntime.connect(configFlag: options.config) else {
      throw ExitCode(1)
    }
    let response = try await client.send(
      .sourcesDisable(source: SourceID(source)), expecting: EmptyData.self)
    await client.close()
    let code = OutputFormatting.emit(
      response, json: options.json, humanSuccess: OutputFormatting.humanEmpty)
    if code != 0 { throw ExitCode(code) }
  }
}

// MARK: - session open / close / list

struct SessionCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "session",
    subcommands: [SessionOpenCommand.self, SessionCloseCommand.self, SessionListCommand.self]
  )
}

struct SessionOpenCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "open", abstract: "Open a session: {sources, slug, start?, vocab?} -> session id.")

  @OptionGroup var options: ClientOptions
  @Option(name: .customLong("slug"), help: "Session slug.") var slug: String
  @Option(name: .customLong("source"), help: "Source id; repeatable.") var sources: [String] = []
  @Option(name: .customLong("vocab"), help: "Optional per-session vocabulary path.")
  var vocab: String?

  func run() async throws {
    guard let client = await ControlClientRuntime.connect(configFlag: options.config) else {
      throw ExitCode(1)
    }
    let request = ControlRequest.sessionOpen(
      sources: sources.map { SourceID($0) }, slug: slug, start: nil, vocab: vocab)
    let response = try await client.send(request, expecting: SessionOpenData.self)
    await client.close()
    let code = OutputFormatting.emit(
      response, json: options.json, humanSuccess: OutputFormatting.humanSessionOpen)
    if code != 0 { throw ExitCode(code) }
  }
}

struct SessionCloseCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "close", abstract: "Close a session by id.")

  @OptionGroup var options: ClientOptions
  @Argument(help: "Session id.") var id: String

  func run() async throws {
    guard let client = await ControlClientRuntime.connect(configFlag: options.config) else {
      throw ExitCode(1)
    }
    let response = try await client.send(.sessionClose(id: id), expecting: EmptyData.self)
    await client.close()
    let code = OutputFormatting.emit(
      response, json: options.json, humanSuccess: OutputFormatting.humanEmpty)
    if code != 0 { throw ExitCode(code) }
  }
}

struct SessionListCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list", abstract: "Open/recent sessions.")

  @OptionGroup var options: ClientOptions

  func run() async throws {
    guard let client = await ControlClientRuntime.connect(configFlag: options.config) else {
      throw ExitCode(1)
    }
    let response = try await client.send(.sessionList, expecting: SessionListData.self)
    await client.close()
    let code = OutputFormatting.emit(
      response, json: options.json, humanSuccess: OutputFormatting.humanSessionList)
    if code != 0 { throw ExitCode(code) }
  }
}

// MARK: - mark

struct MarkCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "mark",
    abstract: "Retroactively define a range (e.g. \"last 30m\") as a session.")

  @OptionGroup var options: ClientOptions
  @Option(name: .customLong("last"), help: "Duration ending now, e.g. 30m, 2h.") var last: String
  @Option(name: .customLong("slug"), help: "Session slug.") var slug: String
  @Option(name: .customLong("source"), help: "Source id; repeatable.") var sources: [String] = []

  func run() async throws {
    let seconds: Double
    switch DurationParsing.seconds(from: last) {
    case .success(let value):
      seconds = value
    case .failure(let error):
      ControlClientRuntime.writeStderr("error: \(error)")
      throw ExitCode(1)
    }

    guard let client = await ControlClientRuntime.connect(configFlag: options.config) else {
      throw ExitCode(1)
    }
    let request = ControlRequest.mark(
      sources: sources.map { SourceID($0) }, slug: slug, range: .lastSeconds(seconds))
    let response = try await client.send(request, expecting: SessionOpenData.self)
    await client.close()
    let code = OutputFormatting.emit(
      response, json: options.json, humanSuccess: OutputFormatting.humanSessionOpen)
    if code != 0 { throw ExitCode(code) }
  }
}

// MARK: - watch

struct WatchCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "watch", abstract: "Subscribe and print the live feed.")

  @OptionGroup var options: ClientOptions
  @Option(name: .customLong("events"), help: "Comma-separated event kinds: vad,session,segment.")
  var events: String = "vad,session,segment"
  @Option(name: .customLong("source"), help: "Source id filter; repeatable. Omit for all sources.")
  var sources: [String] = []

  /// Runs until the daemon closes the connection or the process is
  /// interrupted (Ctrl-C) — `watch` is read-only, so the default SIGINT
  /// disposition (terminate the process) is a clean-enough exit; no custom
  /// handler is needed to protect any state.
  func run() async throws {
    guard let client = await ControlClientRuntime.connect(configFlag: options.config) else {
      throw ExitCode(1)
    }
    let kinds = events.split(separator: ",").compactMap { EventKind(rawValue: String($0)) }
    let request = SubscribeRequest(events: kinds, sources: sources.map { SourceID($0) })

    let stream: AsyncStream<EarsEvent>
    do {
      stream = try await client.subscribe(request)
    } catch {
      ControlClientRuntime.writeStderr("error: could not subscribe: \(error)")
      throw ExitCode(1)
    }

    let encoder = JSONEncoder()
    for await event in stream {
      if options.json {
        if let data = try? encoder.encode(event), let line = String(data: data, encoding: .utf8) {
          print(line)
        }
      } else {
        print(OutputFormatting.humanEvent(event))
      }
    }
  }
}

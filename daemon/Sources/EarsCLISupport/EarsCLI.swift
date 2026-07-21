import EarsConfig
import EarsCore
import EarsLogging
import Foundation

/// Shared entry point for every Phase 0 executable stub (`earsd`, `ears`,
/// `transcribe`, `cleanup`, `summarize`): config discovery
/// (`--print-config`/`--config-path` on the single-purpose tools, `ears
/// config show`/`ears config path` on `ears`, per `docs/configuration.md`),
/// config
/// loading with the full flag/env/file/default layering, and the day-one
/// logging requirements from `docs/logging.md` — bootstrap a `LogSink`, log
/// a `run.start` startup event (resolved config path, effective log level,
/// version, key parameters), and log a final `run.summary` before exiting.
///
/// Each executable is currently a stub with nothing real to do, so "run" is
/// exactly this sequence; it lives here once so the five don't duplicate it.
/// This type does real I/O (reads the environment, the real clock, the
/// filesystem) and so is tier-2/3 glue per `docs/engineering-practices.md`:
/// it is exercised end-to-end by `CLISmokeTests` against the built `earsd`
/// binary rather than unit-tested in isolation, while every pure decision it
/// delegates to — `loadConfig`, `configLayer(fromCLIFlags:)`,
/// ``DefaultLogFilePath``, ``LogLevel``'s severity ordering — is unit-tested
/// where it's defined.
public enum EarsCLI {
  /// The flags every tool supports, independent of `ArgumentParser` so this
  /// module has no parsing-library dependency of its own.
  public struct Arguments: Sendable {
    /// `--config <path>`.
    public var config: String?
    /// `--print-config`: print the resolved, merged config as TOML and exit.
    public var printConfig: Bool
    /// `--config-path`: print which config file was loaded (or that none
    /// was found) and exit.
    public var configPath: Bool
    /// `--log-level <level>`: overrides `[log].level` for this invocation.
    public var logLevel: String?
    /// `--log-file <path>`: overrides `[log].file` for this invocation.
    public var logFile: String?

    public init(
      config: String? = nil,
      printConfig: Bool = false,
      configPath: Bool = false,
      logLevel: String? = nil,
      logFile: String? = nil
    ) {
      self.config = config
      self.printConfig = printConfig
      self.configPath = configPath
      self.logLevel = logLevel
      self.logFile = logFile
    }
  }

  /// Runs the full stub lifecycle for `tool` and returns the process exit
  /// code (0 on success, non-zero on a config or logging-bootstrap failure —
  /// never a silent fallback, per `docs/configuration.md`).
  public static func run(tool: String, version: String, arguments: Arguments) async -> Int32 {
    let environment = ProcessInfo.processInfo.environment
    let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path

    if arguments.configPath {
      printResolvedConfigPath(
        configFlag: arguments.config, environment: environment, homeDirectory: homeDirectory)
      return 0
    }

    let flagsLayer = configLayer(
      fromCLIFlags: CLILogFlags(level: arguments.logLevel, file: arguments.logFile))
    let inputs = ConfigLoadInputs(
      configFlag: arguments.config,
      environment: environment,
      homeDirectory: homeDirectory,
      flags: flagsLayer
    )

    let loaded: LoadedConfig
    switch loadConfig(inputs) {
    case .success(let value):
      loaded = value
    case .failure(let error):
      writeStderr(describe(error))
      return 1
    }

    if arguments.printConfig {
      print(printableConfig(loaded.value))
      return 0
    }

    do {
      try await bootstrapLoggingAndRun(tool: tool, version: version, loaded: loaded)
      return 0
    } catch {
      writeStderr("error: \(tool) failed to start: \(error)")
      return 1
    }
  }

  /// The `--config-path` fast path: resolves which file *would* be read
  /// without loading or validating it, since discovering the path must work
  /// even when the file doesn't exist or is invalid.
  private static func printResolvedConfigPath(
    configFlag: String?,
    environment: [String: String],
    homeDirectory: String
  ) {
    let path = resolveConfigFilePath(
      configFlag: configFlag, environment: environment, homeDirectory: homeDirectory)
    let expanded = (path as NSString).expandingTildeInPath
    if FileManager.default.fileExists(atPath: expanded) {
      print(path)
    } else {
      print("\(path) (no config file found; using built-in defaults)")
    }
  }

  /// Everything a caller needs to log consistently through the one
  /// ``LogSink`` built from resolved config: the sink itself plus the derived
  /// values every ``LogRecord`` and level-gate needs. Returned by
  /// ``makeLogSink(loaded:tool:clock:)`` so `earsd`'s long-running daemon
  /// (`EarsdRuntime`) logs through an *identically-configured* sink as this
  /// CLI's `run.start`/`run.summary`, with no risk of the two constructions
  /// drifting apart.
  public struct LogBootstrap: Sendable {
    public let sink: LogSink
    public let effectiveLevel: LogLevel
    public let subsystem: String
    public let pid: Int32

    public init(sink: LogSink, effectiveLevel: LogLevel, subsystem: String, pid: Int32) {
      self.sink = sink
      self.effectiveLevel = effectiveLevel
      self.subsystem = subsystem
      self.pid = pid
    }
  }

  /// Builds the ``LogSink`` (JSON Lines file + stderr + unified-logging
  /// mirror) from resolved config's `[log]` section — the single construction
  /// site both this CLI bootstrap and the daemon runtime call, so all logging
  /// fans out through the same sink in the same format.
  public static func makeLogSink(
    loaded: LoadedConfig, tool: String, clock: any NowProviding
  ) throws -> LogBootstrap {
    let config = loaded.value
    let dataRoot = stringValue(config, ["data_root"])
    let subsystem = stringValue(config, ["log", "subsystem"], default: "net.tomelliot.ears")
    let oslogEnabled = boolValue(config, ["log", "oslog"], default: true)
    let rotateMaxBytes = intValue(config, ["log", "rotate_max_bytes"], default: 52_428_800)
    let rotateMaxFiles = intValue(config, ["log", "rotate_max_files"], default: 5)
    let effectiveLevel =
      LogLevel(rawValue: stringValue(config, ["log", "level"], default: "info")) ?? .info

    let configuredLogFile = stringValue(config, ["log", "file"])
    let logFilePath =
      configuredLogFile.isEmpty
      ? DefaultLogFilePath.resolve(dataRoot: dataRoot, tool: tool)
      : configuredLogFile

    let pid = ProcessInfo.processInfo.processIdentifier
    let writer = try FileLogWriter(
      url: URL(fileURLWithPath: logFilePath),
      rotation: .init(rotateMaxBytes: rotateMaxBytes, rotateMaxFiles: rotateMaxFiles),
      tool: tool,
      subsystem: subsystem,
      category: tool,
      pid: pid,
      clock: clock
    )
    let unified: any UnifiedLogging =
      oslogEnabled
      ? OSLogUnifiedLogging(subsystem: subsystem, category: tool) : NoOpUnifiedLogging()
    let sink = LogSink(
      file: writer, stderr: RealStderrWriter(), unified: unified, tty: RealTTYDetector())

    return LogBootstrap(
      sink: sink, effectiveLevel: effectiveLevel, subsystem: subsystem, pid: pid)
  }

  /// The normal-run path: bootstrap the ``LogSink`` from resolved config,
  /// emit `run.start` and `run.summary`. Both records are only sent to the
  /// sink when they clear the effective `[log].level` threshold, so
  /// `--log-level error` visibly silences them — the "changes what's
  /// logged" requirement from `docs/configuration.md`.
  private static func bootstrapLoggingAndRun(tool: String, version: String, loaded: LoadedConfig)
    async throws
  {
    let config = loaded.value
    let dataRoot = stringValue(config, ["data_root"])
    let outputRoot = stringValue(config, ["output_root"])

    let clock = SystemClock()
    let bootstrap = try makeLogSink(loaded: loaded, tool: tool, clock: clock)
    let sink = bootstrap.sink
    let subsystem = bootstrap.subsystem
    let pid = bootstrap.pid
    let effectiveLevel = bootstrap.effectiveLevel

    let startup = LogRecord(
      ts: clock.now(),
      level: .info,
      tool: tool,
      subsystem: subsystem,
      category: tool,
      pid: pid,
      event: "run.start",
      fields: [
        LogField("config_path", .string(loaded.configFilePath)),
        LogField("log_level", .string(effectiveLevel.rawValue)),
        LogField("version", .string(version)),
        LogField("data_root", .string(dataRoot)),
        LogField("output_root", .string(outputRoot)),
      ]
    )
    if startup.level >= effectiveLevel {
      try await sink.log(startup)
    }

    let summary = RunSummary.record(
      ts: clock.now(),
      tool: tool,
      subsystem: subsystem,
      category: tool,
      pid: pid,
      fields: [LogField("status", .string("ok"))]
    )
    if summary.level >= effectiveLevel {
      try await sink.log(summary)
    }
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

  // MARK: - Reading a validated ConfigValue tree
  //
  // These read leaf values out of `loaded.value` by key path. Safe to default
  // rather than crash on a shape mismatch: `loadConfig` already ran the
  // value through `Phase0ConfigSchema` validation, so every path read here is
  // guaranteed present with the matching `ConfigValueKind` on any successful
  // load; the defaults are only defensive, not expected to be exercised.

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

  private static func intValue(_ config: ConfigValue, _ path: [String], default defaultValue: Int)
    -> Int
  {
    guard case .int(let value) = walk(config, path) else { return defaultValue }
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

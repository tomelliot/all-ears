import Dispatch
import EarsCLISupport
import EarsConfig
import EarsCore
import EarsDaemonKit
import EarsLogging
import Foundation

/// `earsd`'s real, normal-run (no `--print-config`/`--config-path`) main
/// logic: load and validate config against `earsd`'s own composed schema,
/// resolve `[[earsd.source]]` into an `EarsDaemonConfiguration`, construct
/// and start a real `EarsDaemon`, then keep the process alive until
/// `SIGTERM`.
///
/// `--print-config`/`--config-path` stay on ``EarsCLI/run(tool:version:arguments:)``
/// unchanged (see `Earsd.swift`) -- this type owns only the behavior that's
/// new for this task. It calls `loadConfig` a second time (with `earsd`'s
/// own composed defaults/schema, per that function's own doc comment
/// inviting exactly this) rather than duplicating `EarsCLISupport`'s
/// `LogSink`/`FileLogWriter` bootstrap, which stays exactly as it was.
///
/// This is tier-2/3 process glue -- real config/clock/filesystem/signal I/O
/// -- so it is deliberately thin and exercised end-to-end by `CLISmokeTests`
/// spawning the built binary (with mic-only sources always disabled/absent
/// in those tests -- never a live `MicCaptureBackend.start()`, never TCC).
/// The decision logic it delegates to (``DaemonConfigResolution``) is unit
/// tested directly.
enum EarsdRuntime {
  static func run(arguments: EarsCLI.Arguments) async -> Int32 {
    // Installed before any config loading or daemon construction, not just
    // before the final wait: a `SIGTERM` arriving mid-startup must still be
    // handled by this closure (falling through to a plain `exit(0)`, since
    // there's no daemon yet to stop) rather than by SIGTERM's default
    // terminate-the-process disposition, which `SignalHandling` only
    // silences (`signal(SIGTERM, SIG_IGN)`) once *this* handler takes over.
    // Installing it late left exactly that startup window unhandled -- the
    // control socket appearing (the readiness signal `CLISmokeTests` polls
    // for) doesn't imply this handler is armed yet, so a `SIGTERM` sent right
    // after could still kill the process by signal instead of exiting 0.
    let handle = DaemonHandle()
    // Late-bound so the SIGTERM handler (installed now, before config load) can
    // log through the shared `LogSink` once it exists, and fall back to stderr
    // for anything logged in the pre-config startup window.
    let logHandle = LogHandle()
    let signalSource = SignalHandling.installSIGTERMHandler {
      Task {
        await logHandle.emit("SIGTERM received, shutting down")
        await handle.stopIfStarted()
        await logHandle.emit("stopped")
        // A daemon's run "completes" at shutdown, not at startup, so its
        // `run.summary` belongs here — logging `status=ok` at boot (as the
        // shared CLI bootstrap used to) claimed success before capture had
        // even started, and before the failures issue #25 describes (a
        // `run.summary status=ok` immediately followed by fatal capture
        // errors). A clean SIGTERM shutdown is the honest success signal.
        await logHandle.emitRunSummary()
        exit(0)
      }
    }

    let environment = ProcessInfo.processInfo.environment
    let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path

    let flagsLayer = configLayer(
      fromCLIFlags: CLILogFlags(level: arguments.logLevel, file: arguments.logFile))
    let inputs = ConfigLoadInputs(
      configFlag: arguments.config,
      environment: environment,
      homeDirectory: homeDirectory,
      flags: flagsLayer
    )

    let loaded: LoadedConfig
    switch loadConfig(
      inputs,
      defaults: EarsdConfigSchema.effectiveDefaults,
      schema: EarsdConfigSchema.effectiveSchema
    ) {
    case .success(let value):
      loaded = value
    case .failure(let error):
      writeStderr(describe(error))
      return 1
    }

    // Build the one `LogSink` the whole daemon shares — the same construction
    // the CLI's `run.start`/`run.summary` used (via `EarsCLI.makeLogSink`), so
    // lifecycle, component, and capture logs all fan out identically to the
    // JSON-Lines file, stderr, and the unified-logging mirror. A failure here
    // is non-fatal: `logHandle` keeps its stderr fallback and the daemon logs
    // through a no-op sink, so capture still runs.
    var daemonLogSink: any LogRecordSink = NoOpLogRecordSink()
    if let bootstrap = try? EarsCLI.makeLogSink(
      loaded: loaded, tool: "earsd", clock: SystemClock())
    {
      daemonLogSink = bootstrap.sink
      await logHandle.set(bootstrap.sink, effectiveLevel: bootstrap.effectiveLevel)
    }

    let resolution = DaemonConfigResolution.resolve(config: loaded.value, now: SystemClock().now())
    for skip in resolution.skipped {
      await logHandle.emit("skipping source '\(skip.id)': \(skip.reason)")
    }
    for skip in resolution.skippedTriggerRules {
      await logHandle.emit("skipping trigger rule '\(skip.name)': \(skip.reason)")
    }
    let sourceList =
      resolution.configuration.sources.isEmpty
      ? "(none)"
      : resolution.configuration.sources.map(\.id.rawValue).sorted().joined(separator: ", ")
    await logHandle.emit("run.start: resolved sources: \(sourceList)")

    let daemon: EarsDaemon
    do {
      daemon = try EarsDaemon(
        configuration: resolution.configuration,
        backendFactory: realCaptureBackendFactory(),
        logSink: daemonLogSink
      )
    } catch {
      await logHandle.emit("failed to construct: \(error)", level: .error)
      writeStderr("error: earsd failed to start: \(error)")
      return 1
    }

    // Registered immediately after construction, *before* `daemon.start()`
    // -- not after it succeeds. The daemon boots idle (capture is
    // meeting-scoped), but `start()` can still resume recording: a meeting
    // left active on disk reloads and restarts its sources' capture during
    // `start()`'s `loadFromDisk()`. So a `SIGTERM` landing anywhere during
    // `start()` -- including the window after the socket is visible on disk
    // but before this line used to run -- must still reach `daemon.stop()`,
    // so any already-captured audio gets flushed rather than being silently
    // dropped by the old race where `handle.stopIfStarted()` found nothing
    // registered yet and just called `exit(0)`.
    //
    // Safe even though this can now let a concurrent `stop()` interleave
    // with an in-flight `start()` (Swift actor reentrancy): whatever `stop()`
    // tears down stays torn down, because the `SIGTERM` handler's `exit(0)`
    // terminates the whole process immediately afterward -- there is no
    // window left for `start()` to resume and "revive" anything.
    // `EarsDaemon.stop()` is also safe to call before `start()` has built
    // any `CaptureActor` at all: with no live actors, its per-actor teardown
    // is simply a no-op.
    await handle.set(daemon)

    do {
      try await daemon.start()
    } catch {
      await logHandle.emit("failed to start: \(error)", level: .error)
      writeStderr("error: earsd failed to start: \(error)")
      return 1
    }
    await logHandle.emit("started (socket: \(resolution.configuration.socketPath))")

    await waitForever()
    // Unreachable: `waitForever()` only returns via the SIGTERM handler's
    // `exit(0)`, which terminates the process before this executes.
    _ = signalSource
    return 0
  }

  /// Suspends forever: `EarsDaemon.stop()` already stops every
  /// `CaptureActor` (per its own contract), so the SIGTERM handler installed
  /// in ``run(arguments:)`` calls that directly and exits, rather than
  /// routing through `EarsDaemonKit.ShutdownCoordinator` (redundant here --
  /// there's exactly one daemon instance, not a collection of actors this
  /// call site would otherwise have to assemble a coordinator around).
  private static func waitForever() async {
    while true {
      try? await Task.sleep(for: .seconds(3_600))
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
}

/// Late-bound holder for the shared ``LogSink``, so the `SIGTERM` handler —
/// installed at the very top of ``EarsdRuntime/run(arguments:)``, before config
/// is loaded and the sink can be built — still logs through the same sink as
/// everything else once it exists, and degrades to stderr for the pre-config
/// startup window. An `actor` for the same reason as ``DaemonHandle``: the
/// escaping signal-handler `Task` and `run(arguments:)` both touch it.
private actor LogHandle {
  private var sink: (any LogRecordSink)?
  /// The effective `[log].level`, captured alongside the sink so the shutdown
  /// `run.summary` respects the same threshold the CLI bootstrap applies to
  /// `run.start` (a `--log-level error` run keeps both info-level records out
  /// of the file). Defaults to `.info` until ``set(_:effectiveLevel:)`` runs.
  private var effectiveLevel: LogLevel = .info
  private let pid = ProcessInfo.processInfo.processIdentifier
  private let clock = SystemClock()

  func set(_ sink: any LogRecordSink, effectiveLevel: LogLevel) {
    self.sink = sink
    self.effectiveLevel = effectiveLevel
  }

  /// Logs one lifecycle message as a `daemon.log` ``LogRecord`` through the
  /// sink once ``set(_:effectiveLevel:)`` has run; before that (e.g. a
  /// `SIGTERM` during early startup) it writes the bare message to stderr so
  /// nothing is lost.
  func emit(_ message: String, level: LogLevel = .notice, event: String = "daemon.log") async {
    guard let sink else {
      FileHandle.standardError.write(Data(("earsd: " + message + "\n").utf8))
      return
    }
    let record = LogRecord(
      ts: clock.now(), level: level, tool: "earsd",
      subsystem: "net.tomelliot.ears", category: "earsd", pid: pid,
      event: event, msg: message)
    try? await sink.log(record)
  }

  /// Emits the daemon's final `run.summary` at shutdown. Gated by the
  /// effective log level (like the CLI bootstrap's `run.start`), and skipped
  /// entirely before the sink exists — a `SIGTERM` during the pre-config
  /// startup window has no meaningful run to summarize.
  func emitRunSummary(status: String = "ok") async {
    guard let sink else { return }
    guard LogLevel.info >= effectiveLevel else { return }
    let record = RunSummary.record(
      ts: clock.now(), level: .info, tool: "earsd",
      subsystem: "net.tomelliot.ears", category: "earsd", pid: pid,
      fields: [LogField("status", .string(status))])
    try? await sink.log(record)
  }
}

/// Holds the (not-yet-constructed-until-later) `EarsDaemon` the `SIGTERM`
/// handler needs to stop, so the handler can be installed once, immediately,
/// at the very top of ``EarsdRuntime/run(arguments:)`` -- before config
/// loading or daemon construction -- rather than racing a signal that could
/// arrive during that startup window. An `actor` (not a raw `Mutex` box):
/// capturing a plain mutable box in the escaping `Task` the signal handler
/// spawns, while the same binding is still written to later in `run(arguments:)`,
/// trips Swift's "sending closure" data-race diagnostic even though a
/// `Mutex` would be safe at runtime; an actor reference is the idiomatic
/// shape the concurrency checker already understands for shared mutable
/// state touched from multiple tasks.
private actor DaemonHandle {
  private var daemon: EarsDaemon?

  func set(_ daemon: EarsDaemon) {
    self.daemon = daemon
  }

  /// Stops the daemon if ``set(_:)`` already ran (which `run(arguments:)`
  /// does immediately after construction, *before* calling `start()` --
  /// see that call site's doc comment for why stopping a not-yet-fully-
  /// started daemon is safe), or does nothing if a `SIGTERM` arrived before
  /// the daemon even finished constructing -- still a clean shutdown either
  /// way, since `exit(0)` follows regardless.
  func stopIfStarted() async {
    if let daemon { await daemon.stop() }
  }
}

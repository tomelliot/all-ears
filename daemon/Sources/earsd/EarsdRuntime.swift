import Dispatch
import EarsCLISupport
import EarsConfig
import EarsCore
import EarsDaemonKit
import Foundation
import os

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
  private static let logger = Logger(subsystem: "net.tomelliot.ears", category: "earsd")

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
    let log: @Sendable (String) -> Void = { message in
      logger.notice("\(message, privacy: .public)")
      FileHandle.standardError.write(Data(("earsd: " + message + "\n").utf8))
    }
    let signalSource = SignalHandling.installSIGTERMHandler {
      Task {
        log("SIGTERM received, shutting down")
        await handle.stopIfStarted()
        log("stopped")
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

    let resolution = DaemonConfigResolution.resolve(config: loaded.value, now: SystemClock().now())
    for skip in resolution.skipped {
      log("skipping source '\(skip.id)': \(skip.reason)")
    }
    for skip in resolution.skippedTriggerRules {
      log("skipping trigger rule '\(skip.name)': \(skip.reason)")
    }
    let sourceList =
      resolution.configuration.sources.isEmpty
      ? "(none)"
      : resolution.configuration.sources.map(\.id.rawValue).sorted().joined(separator: ", ")
    log("run.start: resolved sources: \(sourceList)")

    let daemon: EarsDaemon
    do {
      daemon = try EarsDaemon(
        configuration: resolution.configuration,
        backendFactory: realCaptureBackendFactory(),
        log: log
      )
    } catch {
      log("failed to construct: \(error)")
      writeStderr("error: earsd failed to start: \(error)")
      return 1
    }

    // Registered immediately after construction, *before* `daemon.start()`
    // -- not after it succeeds. `daemon.start()` begins buffering real audio
    // (each source's `CaptureActor.start()`) before it binds the control
    // socket, so a `SIGTERM` landing anywhere during `start()` -- including
    // the narrow window after the socket is already visible on disk but
    // before this line used to run -- must still reach `daemon.stop()` so
    // any already-captured audio gets flushed, rather than being silently
    // dropped by the old race where `handle.stopIfStarted()` found nothing
    // registered yet and just called `exit(0)`. (`CLISmokeTests`'
    // `normalRunWithSyntheticBackendWritesRealFilesToDisk` -- the first test
    // to spawn a real `earsd` with real audio actually flowing -- caught
    // this by sending `SIGTERM` the instant the socket appeared.)
    //
    // Safe even though this can now let a concurrent `stop()` interleave
    // with an in-flight `start()` on the same actor (Swift actor
    // reentrancy): whatever `stop()` tears down stays torn down, because
    // the `SIGTERM` handler's `exit(0)` terminates the whole process
    // immediately afterward -- there is no window left for `start()` to
    // resume and "revive" anything. `EarsDaemon.stop()` is also safe to
    // call before `start()` has done anything at all: every `CaptureActor`
    // already exists (built in `EarsDaemon.init()`) but starts `.disabled`,
    // so `stop()`'s per-actor teardown is a no-op until a source has
    // actually started.
    await handle.set(daemon)

    do {
      try await daemon.start()
    } catch {
      log("failed to start: \(error)")
      writeStderr("error: earsd failed to start: \(error)")
      return 1
    }
    log("started (socket: \(resolution.configuration.socketPath))")

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

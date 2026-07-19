import Dispatch
import EarsCLISupport
import EarsConfig
import EarsCore
import Foundation
import Synchronization

/// `transcribe --follow`'s real entry point — the follow-mode counterpart of
/// ``TranscribeRuntime``, and deliberately just as thin: loads config,
/// resolves `data_root`/`output_root`/`[transcribe]` selection *plus* the
/// daemon's `socket_path` (same precedence and default as `ears`/`earsd`:
/// empty ⇒ `<data_root>/runtime/earsd.sock`) for the live-feed publisher,
/// installs SIGINT/SIGTERM handlers that flip the pipeline's stop seam, and
/// delegates everything else to ``TranscribeFollowPipeline``.
///
/// Signal handling mirrors `EarsDaemonKit.SignalHandling`'s mechanism
/// (ignore the default disposition, then a `DispatchSourceSignal`): a signal
/// requests a *graceful* stop — the pipeline finalises the in-flight window,
/// flushes the held-back tail, and completes the transcript file before
/// exiting — rather than killing the process mid-write.
enum FollowRuntime {
  static func run(
    arguments: EarsCLI.Arguments, inputs: TranscribeFollowPipeline.Inputs
  ) async -> Int32 {
    let environment = ProcessInfo.processInfo.environment
    let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
    let flagsLayer = configLayer(
      fromCLIFlags: CLILogFlags(level: arguments.logLevel, file: arguments.logFile))
    let loadInputs = ConfigLoadInputs(
      configFlag: arguments.config,
      environment: environment,
      homeDirectory: homeDirectory,
      flags: flagsLayer
    )

    let loaded: LoadedConfig
    switch loadConfig(loadInputs) {
    case .success(let value): loaded = value
    case .failure(let error):
      writeStderr(describe(error))
      return 1
    }

    let root = loaded.value
    let dataRootPath = stringValue(root, ["data_root"])
    guard !dataRootPath.isEmpty else {
      writeStderr("error: data_root is not configured")
      return 1
    }
    let outputRootPath = stringValue(root, ["output_root"])
    let backendName = stringValue(root, ["transcribe", "backend"], default: "fluidaudio")
    let modelIdentifier = stringValue(root, ["transcribe", "model"])
    let compute = TranscribeRuntime.computePreference(
      stringValue(root, ["transcribe", "compute"], default: "automatic"))

    let configuredSocketPath = stringValue(root, ["socket_path"])
    let socketPath =
      configuredSocketPath.isEmpty
      ? DefaultSocketPath.resolve(dataRoot: dataRootPath) : configuredSocketPath

    // Graceful stop on SIGINT/SIGTERM: flip the flag the pipeline polls.
    // The dispatch sources must stay referenced for the process lifetime.
    let stopRequested = Mutex<Bool>(false)
    let signalSources = installStopSignalHandlers {
      stopRequested.withLock { $0 = true }
    }
    defer { for source in signalSources { source.cancel() } }

    let publisher = SegmentEventPublisher(
      socketPath: socketPath,
      log: { message in
        FileHandle.standardError.write(Data(("transcribe: " + message + "\n").utf8))
      })

    let exitCode = await TranscribeFollowPipeline.run(
      inputs: inputs,
      dataRoot: URL(fileURLWithPath: dataRootPath),
      outputRoot: URL(fileURLWithPath: outputRootPath.isEmpty ? "." : outputRootPath),
      backendName: backendName,
      dependencies: .production(
        loadOptions: LoadOptions(
          modelIdentifier: modelIdentifier.isEmpty ? nil : modelIdentifier,
          compute: compute),
        publisher: publisher,
        isStopped: { stopRequested.withLock { $0 } })
    )
    await publisher.shutdown()
    return exitCode
  }

  /// Installs SIGINT + SIGTERM handlers that call `onStop` on each
  /// delivery, returning the sources the caller must keep alive.
  private static func installStopSignalHandlers(
    onStop: @escaping @Sendable () -> Void
  ) -> [DispatchSourceSignal] {
    let queue = DispatchQueue(label: "net.tomelliot.ears.transcribe.follow-signals")
    return [SIGINT, SIGTERM].map { signalNumber in
      signal(signalNumber, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
      source.setEventHandler(handler: onStop)
      source.resume()
      return source
    }
  }

  // MARK: - Config plumbing (mirrors TranscribeRuntime's private helpers)

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

  private static func stringValue(
    _ config: ConfigValue, _ path: [String], default defaultValue: String = ""
  ) -> String {
    guard case .string(let value) = walk(config, path) else { return defaultValue }
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

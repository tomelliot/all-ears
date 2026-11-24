import Foundation
import Testing

/// Tier-3 smoke tests that spawn the real, built `earsd`/`ears` binaries via
/// `Process` and assert on their observable behaviour (exit codes,
/// stdout/stderr, files written, socket wiring) -- the outermost layer of
/// `docs/engineering-practices.md`'s test pyramid.
///
/// A normal `earsd` invocation now runs a real daemon that stays alive until
/// `SIGTERM` (see `Sources/earsd/EarsdRuntime.swift`), so every test that
/// spawns it that way sends `SIGTERM` once its control socket appears rather
/// than waiting for it to exit on its own. **Every test here either disables
/// or omits the `mic` source** (`[earsd] source = []`, or an explicit
/// `enabled = false`/unsupported `class`), **or sets
/// `ALLEARS_CAPTURE_BACKEND=synthetic`** to divert a real, enabled mic
/// source to a scripted `SyntheticCaptureBackend` (see
/// `RealCaptureBackendFactory.swift`'s doc comment) -- per this task's
/// constraint: no automated test may spawn a real `earsd` with a live mic
/// source actually reaching a real `MicCaptureBackend`, which would touch
/// Core Audio/TCC.
@Suite("CLI Smoke: earsd + ears")
struct CLISmokeTests {
  /// Locates a built product binary next to this test bundle.
  ///
  /// Swift Testing runs inside an `.xctest` bundle even for non-XCTest
  /// suites under `swift test` (there's no `XCTestCase` to hang a
  /// `Bundle(for:)` lookup off, so this uses a plain class defined in this
  /// file instead -- `Bundle(for:)` works for any Swift class on Darwin).
  /// SwiftPM places every product of a build -- the `.xctest` bundle *and*
  /// each executable target -- as siblings in one products directory
  /// (`.build/<triple>/<configuration>/`), confirmed by inspecting
  /// `swift build --build-tests`'s output for this package: `earsd` and
  /// `AllEarsPackageTests.xctest` land side by side. So the test bundle's
  /// own directory *is* the products directory both binaries live in.
  private final class BundleMarker {}

  private static func productsDirectory() throws -> URL {
    let bundleURL = Bundle(for: BundleMarker.self).bundleURL
    // The .xctest bundle itself is a directory inside the products
    // directory; its parent is where sibling executables live.
    return bundleURL.deletingLastPathComponent()
  }

  private static func binaryURL(_ name: String) throws -> URL {
    let url = try productsDirectory().appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw SmokeTestSetupError.binaryNotFound(url.path)
    }
    return url
  }

  private static func earsdBinaryURL() throws -> URL { try binaryURL("earsd") }
  private static func earsBinaryURL() throws -> URL { try binaryURL("ears") }

  private enum SmokeTestSetupError: Error, CustomStringConvertible {
    case binaryNotFound(String)

    var description: String {
      switch self {
      case .binaryNotFound(let path):
        return "expected a built binary at \(path) -- run `swift build` before `swift test`"
      }
    }
  }

  private struct RunResult {
    var exitCode: Int32
    var stdout: String
    var stderr: String
  }

  /// Runs `executable` with `arguments` and `environment` to completion.
  /// `environment` is used as-is (not merged with the parent's) so tests
  /// control the layering precisely -- no ambient `EARS_*` variable from the
  /// host shell can leak into an assertion. Only for invocations that exit
  /// on their own (`--print-config`/`--config-path`, any `ears` subcommand);
  /// see ``withRunningDaemon(configPath:environment:extraArguments:socketReadyTimeout:body:)``
  /// for `earsd`'s normal, never-exits-on-its-own run mode.
  private static func run(
    _ executable: URL, _ arguments: [String], environment: [String: String] = [:]
  ) throws -> RunResult {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = environment

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try process.run()
    process.waitUntilExit()

    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

    return RunResult(
      exitCode: process.terminationStatus,
      stdout: String(data: stdoutData, encoding: .utf8) ?? "",
      stderr: String(data: stderrData, encoding: .utf8) ?? ""
    )
  }

  private static func runEarsd(_ arguments: [String], environment: [String: String] = [:]) throws
    -> RunResult
  {
    try run(try earsdBinaryURL(), arguments, environment: environment)
  }

  private static func runEars(_ arguments: [String], environment: [String: String] = [:]) throws
    -> RunResult
  {
    try run(try earsBinaryURL(), arguments, environment: environment)
  }

  /// A short, unique temp socket path. `sockaddr_un.sun_path` caps at 104
  /// bytes, so `/tmp` (not the long scratchpad dir) keeps us well under, per
  /// `EarsDaemonKitTests`' precedent.
  private static func tempSocketPath() -> String {
    "/tmp/ears-cli-smoke-\(UUID().uuidString).sock"
  }

  private static func waitForSocket(at path: String, timeout: TimeInterval = 5) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if FileManager.default.fileExists(atPath: path) { return true }
      usleep(20_000)
    }
    return false
  }

  /// Handle on a spawned, still-running `earsd` normal-run process: polls
  /// for its control socket to appear (proof `EarsDaemon.start()` finished
  /// binding it), yields it to `body` for `ears`-side assertions against the
  /// live daemon, then sends `SIGTERM` (matching `Process.terminate()`'s
  /// documented signal) and waits for the graceful-shutdown exit, per
  /// `earsd`'s installed `SIGTERM` handler.
  private static func withRunningDaemon<T>(
    configPath: String,
    environment: [String: String] = [:],
    extraArguments: [String] = [],
    socketReadyTimeout: TimeInterval = 5,
    body: (String) throws -> T
  ) throws -> (result: T, socketBecameReady: Bool, exitCode: Int32, stderr: String) {
    let socketPath = tempSocketPath()
    var env = environment
    env["EARS_SOCKET_PATH"] = socketPath

    let process = Process()
    process.executableURL = try earsdBinaryURL()
    process.arguments = ["--config", configPath] + extraArguments
    process.environment = env
    let stderrPipe = Pipe()
    process.standardError = stderrPipe
    process.standardOutput = Pipe()

    try process.run()
    let ready = waitForSocket(at: socketPath, timeout: socketReadyTimeout)

    let result = try body(socketPath)

    process.terminate()
    process.waitUntilExit()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

    return (
      result, ready, process.terminationStatus, String(data: stderrData, encoding: .utf8) ?? ""
    )
  }

  /// A temp directory that cleans itself up when the test struct is torn
  /// down, mirroring `ConfigLoaderTests`' fixture pattern.
  private final class TempDirectory {
    let url: URL

    init() {
      url = FileManager.default.temporaryDirectory
        .appendingPathComponent("CLISmokeTests-\(UUID().uuidString)", isDirectory: true)
      try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func write(_ contents: String, named name: String) -> String {
      let fileURL = url.appendingPathComponent(name)
      try? contents.write(to: fileURL, atomically: true, encoding: .utf8)
      return fileURL.path
    }

    deinit {
      try? FileManager.default.removeItem(at: url)
    }
  }

  // MARK: - earsd: --print-config / --config-path (unchanged day-one behavior)

  @Test("--print-config reflects file -> env layering, and a flag on top of that")
  func printConfigReflectsLayering() throws {
    let temp = TempDirectory()
    let configPath = temp.write(
      """
      data_root = "/from-file/data"

      [log]
      level = "debug"
      format = "json"
      """,
      named: "config.toml"
    )

    // env overrides the file's "debug".
    let envResult = try Self.runEarsd(
      ["--config", configPath, "--print-config"],
      environment: ["EARS_LOG__LEVEL": "notice"]
    )
    #expect(envResult.exitCode == 0)
    #expect(envResult.stdout.contains("data_root = '/from-file/data'"))
    #expect(envResult.stdout.contains("level = 'notice'"))
    #expect(envResult.stdout.contains("format = 'json'"))

    // --log-level overrides the env layer on top of that.
    let flagResult = try Self.runEarsd(
      ["--config", configPath, "--print-config", "--log-level", "error"],
      environment: ["EARS_LOG__LEVEL": "notice"]
    )
    #expect(flagResult.exitCode == 0)
    #expect(flagResult.stdout.contains("level = 'error'"))
  }

  @Test("--set overrides the config file and the env layer, and rejects a malformed value")
  func setOverridesEveryLowerLayer() throws {
    let temp = TempDirectory()
    let configPath = temp.write(
      """
      [log]
      level = "debug"

      [earsd.vad]
      min_silence_ms = 700
      """,
      named: "config.toml"
    )

    // --set beats both the file's "debug" and the env layer's "notice", and
    // reaches a nested key with a coerced integer value.
    let result = try Self.runEarsd(
      [
        "--config", configPath, "--print-config",
        "--set", "log.level=error",
        "--set", "earsd.vad.min_silence_ms=250",
      ],
      environment: ["EARS_LOG__LEVEL": "notice"]
    )
    #expect(result.exitCode == 0)
    #expect(result.stdout.contains("level = 'error'"))
    #expect(result.stdout.contains("min_silence_ms = 250"))

    // A malformed --set is a precise, non-zero failure, never a silent drop.
    let malformed = try Self.runEarsd(
      ["--config", configPath, "--print-config", "--set", "log.level"])
    #expect(malformed.exitCode != 0)
    #expect(malformed.stderr.contains("invalid --set override"))
    #expect(malformed.stderr.contains("log.level"))
  }

  @Test("--config-path reports the resolved file when one exists")
  func configPathReportsResolvedFile() throws {
    let temp = TempDirectory()
    let configPath = temp.write("data_root = \"/from-file/data\"", named: "config.toml")

    let result = try Self.runEarsd(["--config", configPath, "--config-path"])
    #expect(result.exitCode == 0)
    #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == configPath)
  }

  @Test("--config-path clearly reports when no config file is found")
  func configPathReportsNoFileFound() throws {
    let temp = TempDirectory()
    let missingPath = temp.url.appendingPathComponent("does-not-exist.toml").path

    let result = try Self.runEarsd(["--config", missingPath, "--config-path"])
    #expect(result.exitCode == 0)
    #expect(result.stdout.contains(missingPath))
    #expect(result.stdout.contains("no config file found"))
  }

  @Test("an invalid config file exits non-zero with a precise, actionable message on stderr")
  func invalidConfigExitsNonZero() throws {
    let temp = TempDirectory()
    let configPath = temp.write("bogus_top_level_key = \"nope\"", named: "config.toml")

    let result = try Self.runEarsd(["--config", configPath, "--print-config"])
    #expect(result.exitCode != 0)
    #expect(result.stderr.contains("bogus_top_level_key"))
  }

  // MARK: - earsd: normal run (real daemon, always mic-free in these tests)

  @Test(
    "a normal run with --log-file writes valid JSON Lines, including a startup event and a run.summary, then shuts down cleanly on SIGTERM"
  )
  func normalRunWritesJSONLinesLog() throws {
    let temp = TempDirectory()
    let logPath = temp.url.appendingPathComponent("earsd.jsonl").path
    let configPath = temp.write(
      """
      data_root = "\(temp.url.path)/data"

      [earsd]
      source = []
      """,
      named: "config.toml"
    )

    let run = try Self.withRunningDaemon(
      configPath: configPath, extraArguments: ["--log-file", logPath]
    ) { _ in }
    #expect(run.socketBecameReady)
    #expect(run.exitCode == 0)

    #expect(FileManager.default.fileExists(atPath: logPath))
    let contents = try String(contentsOfFile: logPath, encoding: .utf8)
    let lines = contents.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    #expect(!lines.isEmpty)

    var events: [String] = []
    for line in lines {
      let data = try #require(line.data(using: .utf8))
      let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      let object = try #require(parsed, "line did not parse as a JSON object: \(line)")
      let event = try #require(object["event"] as? String)
      events.append(event)
      #expect(object["ts"] is String)
      #expect(object["tool"] as? String == "earsd")
      #expect(object["pid"] is Int)
    }

    #expect(events.contains("run.start"))
    #expect(events.contains("run.summary"))
  }

  @Test("--log-level above a record's level suppresses it from the log file")
  func logLevelFiltersRecords() throws {
    let temp = TempDirectory()
    let logPath = temp.url.appendingPathComponent("earsd.jsonl").path
    let configPath = temp.write(
      """
      data_root = "\(temp.url.path)/data"

      [earsd]
      source = []
      """,
      named: "config.toml"
    )

    let run = try Self.withRunningDaemon(
      configPath: configPath, extraArguments: ["--log-file", logPath, "--log-level", "error"]
    ) { _ in }
    #expect(run.socketBecameReady)
    #expect(run.exitCode == 0)

    // FileLogWriter still creates the file; at --log-level error, the
    // info-level run.start/run.summary records never reach it.
    let contents = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
    #expect(!contents.contains("\"event\":\"run.start\""))
    #expect(!contents.contains("\"event\":\"run.summary\""))
  }

  @Test(
    "a normal run skips a disabled source and an unsupported source class, logging why, and still shuts down cleanly"
  )
  func normalRunSkipsUnsupportedAndDisabledSources() throws {
    let temp = TempDirectory()
    let configPath = temp.write(
      """
      data_root = "\(temp.url.path)/data"

      [earsd]
      [[earsd.source]]
      id = "mic"
      class = "mic"
      enabled = false

      [[earsd.source]]
      id = "browser:meet"
      class = "browser"
      """,
      named: "config.toml"
    )

    let run = try Self.withRunningDaemon(configPath: configPath) { _ in }
    #expect(run.socketBecameReady)
    #expect(run.exitCode == 0)
    #expect(run.stderr.contains("skipping source 'mic'"))
    #expect(run.stderr.contains("disabled in config"))
    #expect(run.stderr.contains("skipping source 'browser:meet'"))
    #expect(run.stderr.contains("not yet supported"))
    #expect(run.stderr.contains("resolved sources: (none)"))
    #expect(run.stderr.contains("SIGTERM received"))
    #expect(run.stderr.contains("stopped"))
  }

  @Test(
    "the session-scoped lifecycle: a fresh daemon writes nothing; a session start records real chunk files and a chunk index event to disk, and session end stops capture"
  )
  func sessionScopedLifecycleWritesRealFilesToDisk() throws {
    // Unlike every other test in this file, this one *does* declare an
    // enabled mic-class source -- safe only because
    // `ALLEARS_CAPTURE_BACKEND=synthetic` (set below, in the spawned
    // process's own environment) diverts `RealCaptureBackendFactory` to a
    // scripted `SyntheticCaptureBackend` for every source (see that file's
    // doc comment -- and note it is deliberately not `EARS_`-prefixed,
    // since that prefix gets swept into real layered config and rejected as
    // an unknown key), so this still never touches Core Audio or prompts
    // TCC. This is the one test in this file that proves a real, spawned
    // `earsd` binary records to disk -- and, since recording is now
    // session-scoped, that it does so only while a session is active: a fresh
    // daemon writes no source directory, and a `session start`/`session end`
    // round-trip is what produces (and finalizes) the chunk files.
    let temp = TempDirectory()
    let dataRootPath = temp.url.appendingPathComponent("data").path
    let configPath = temp.write(
      """
      data_root = "\(dataRootPath)"

      [earsd]
      [[earsd.source]]
      id = "mic"
      class = "mic"
      """,
      named: "config.toml"
    )

    // Audio is session-scoped: the mic's directory lands under
    // sessions/<id>/sources/mic, where <id> is minted by the daemon at
    // `session start`. The exact id is recovered after the run by
    // enumerating sessions/ (exactly one session exists in this test).
    let sessionsDirectory = URL(fileURLWithPath: dataRootPath)
      .appendingPathComponent("sessions")

    let run = try Self.withRunningDaemon(
      configPath: configPath,
      environment: ["ALLEARS_CAPTURE_BACKEND": "synthetic"]
    ) { socketPath -> Bool in
      // A fresh, idle daemon has recorded nothing: no session directory (and
      // so no source directory) exists.
      let wroteNothingIdle = !FileManager.default.fileExists(atPath: sessionsDirectory.path)

      // Drive the session lifecycle over the real control socket via `ears`.
      // A manual session naming `mic` starts its capture; ending it stops and
      // flushes the in-progress chunk to disk.
      let started = try Self.runEars(
        ["session", "start", "--source", "mic", "--json", "--config", configPath],
        environment: ["EARS_SOCKET_PATH": socketPath])
      let object =
        (try? JSONSerialization.jsonObject(
          with: Data(started.stdout.utf8))) as? [String: Any]
      let sessionID = (object?["id"] as? String) ?? ""
      _ = try Self.runEars(
        ["session", "end", sessionID, "--config", configPath],
        environment: ["EARS_SOCKET_PATH": socketPath])
      return wroteNothingIdle && started.exitCode == 0 && !sessionID.isEmpty
    }
    #expect(run.socketBecameReady)
    #expect(run.exitCode == 0)
    #expect(run.result, "expected an idle daemon to write nothing, then a session to start cleanly")

    let sessionIDs =
      (try? FileManager.default.contentsOfDirectory(atPath: sessionsDirectory.path)) ?? []
    #expect(sessionIDs.count == 1, "expected exactly one session directory, got \(sessionIDs)")
    let sourceDirectory =
      sessionsDirectory
      .appendingPathComponent(sessionIDs.first ?? "missing")
      .appendingPathComponent("sources")
      .appendingPathComponent("mic")

    let chunkFileNames =
      ((try? FileManager.default.contentsOfDirectory(
        atPath: sourceDirectory.appendingPathComponent("chunks").path)) ?? [])
      + ((try? FileManager.default.contentsOfDirectory(
        atPath: sourceDirectory.appendingPathComponent("asr").path)) ?? [])
    #expect(!chunkFileNames.isEmpty, "expected at least one chunk file under chunks/ or asr/")

    let indexContents =
      (try? String(
        contentsOfFile: sourceDirectory.appendingPathComponent("chunks.jsonl").path,
        encoding: .utf8)) ?? ""
    let indexLines = indexContents.split(separator: "\n", omittingEmptySubsequences: true)
    let hasChunkEvent = indexLines.contains { line in
      guard let data = line.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return false }
      // The structural index (chunks.jsonl) discriminates its event kind on the
      // "t" field, per docs/data-formats.md's "The index" section -- distinct
      // from the structured-log JSON Lines format's "event" field asserted
      // on elsewhere in this file.
      return object["t"] as? String == "chunk"
    }
    #expect(hasChunkEvent, "expected a 't':'chunk' event in chunks.jsonl:\n\(indexContents)")
  }

  // MARK: - ears: config show / path (day-one config discovery, subcommand spelling)

  @Test("ears config show reflects file -> env layering, and a flag on top of that")
  func earsConfigShowReflectsLayering() throws {
    let temp = TempDirectory()
    let configPath = temp.write(
      """
      data_root = "/from-file/data"

      [log]
      level = "debug"
      format = "json"
      """,
      named: "config.toml"
    )

    // env overrides the file's "debug".
    let envResult = try Self.runEars(
      ["config", "show", "--config", configPath],
      environment: ["EARS_LOG__LEVEL": "notice"]
    )
    #expect(envResult.exitCode == 0)
    #expect(envResult.stdout.contains("data_root = '/from-file/data'"))
    #expect(envResult.stdout.contains("level = 'notice'"))
    #expect(envResult.stdout.contains("format = 'json'"))

    // --log-level overrides the env layer on top of that.
    let flagResult = try Self.runEars(
      ["config", "show", "--config", configPath, "--log-level", "error"],
      environment: ["EARS_LOG__LEVEL": "notice"]
    )
    #expect(flagResult.exitCode == 0)
    #expect(flagResult.stdout.contains("level = 'error'"))
  }

  @Test("ears config path reports the resolved file, or clearly that none was found")
  func earsConfigPathReportsResolvedFile() throws {
    let temp = TempDirectory()
    let configPath = temp.write("data_root = \"/from-file/data\"", named: "config.toml")

    let found = try Self.runEars(["config", "path", "--config", configPath])
    #expect(found.exitCode == 0)
    #expect(found.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == configPath)

    let missingPath = temp.url.appendingPathComponent("does-not-exist.toml").path
    let missing = try Self.runEars(["config", "path", "--config", missingPath])
    #expect(missing.exitCode == 0)
    #expect(missing.stdout.contains(missingPath))
    #expect(missing.stdout.contains("no config file found"))
  }

  @Test(
    "ears config describe lists settings from every tool with types, defaults, and descriptions")
  func earsConfigDescribeListsEverySetting() throws {
    let result = try Self.runEars(["config", "describe"])
    #expect(result.exitCode == 0)
    // A shared Phase-0 key, an earsd key, an LLM-stage key, and a transcribe
    // key — proving the listing spans every tool's slice, not just one.
    #expect(result.stdout.contains("log.level : string"))
    #expect(result.stdout.contains("[earsd]"))
    #expect(result.stdout.contains("llm.model : string"))
    #expect(result.stdout.contains("transcribe.backend : string = \"fluidaudio\""))
    // A declared description surfaces alongside the key.
    #expect(result.stdout.contains("Speaker-diarization backend"))
  }

  @Test("ears with no subcommand runs the status dashboard (here: failing to reach a daemon)")
  func earsBareRunsStatus() throws {
    let temp = TempDirectory()
    let configPath = temp.write(
      "data_root = \"\(temp.url.path)/data\"",
      named: "config.toml"
    )
    // Bare `ears` defaults to `status`, so with no daemon it fails exactly
    // the way `ears status` does — not with a help listing.
    let result = try Self.runEars(
      ["--config", configPath],
      environment: ["EARS_SOCKET_PATH": Self.tempSocketPath()])
    #expect(result.exitCode != 0)
    #expect(result.stderr.contains("could not reach earsd"))
    #expect(!result.stdout.contains("SUBCOMMANDS"))
  }

  @Test("ears with no subcommand renders the dashboard against a live earsd")
  func earsBareRendersDashboardAgainstLiveDaemon() throws {
    let temp = TempDirectory()
    let configPath = temp.write(
      """
      data_root = "\(temp.url.path)/data"

      [earsd]
      source = []
      """,
      named: "config.toml"
    )

    let run = try Self.withRunningDaemon(configPath: configPath) { socketPath in
      try Self.runEars(
        ["--config", configPath],
        environment: ["EARS_SOCKET_PATH": socketPath])
    }
    #expect(run.socketBecameReady)
    #expect(run.result.exitCode == 0)
    #expect(run.result.stdout.contains("earsd — up"))
    #expect(run.result.stdout.contains("idle"))
  }

  // MARK: - ears: real subcommands against a live earsd (always source-free)

  @Test("ears status reflects a real earsd over the real control socket")
  func earsStatusAgainstLiveDaemon() throws {
    let temp = TempDirectory()
    let configPath = temp.write(
      """
      data_root = "\(temp.url.path)/data"

      [earsd]
      source = []
      """,
      named: "config.toml"
    )

    let run = try Self.withRunningDaemon(configPath: configPath) { socketPath in
      try Self.runEars(
        ["status", "--config", configPath, "--json"],
        environment: ["EARS_SOCKET_PATH": socketPath])
    }
    #expect(run.socketBecameReady)
    #expect(run.result.exitCode == 0)
    #expect(run.result.stdout.contains("\"uptime_s\""))
    #expect(run.result.stdout.contains("\"sources\":[]"))
  }

  @Test("ears status --verbose traces the socket resolution and request/reply exchange to stderr")
  func earsStatusVerboseTracesExchange() throws {
    let temp = TempDirectory()
    let configPath = temp.write(
      """
      data_root = "\(temp.url.path)/data"

      [earsd]
      source = []
      """,
      named: "config.toml"
    )

    let run = try Self.withRunningDaemon(configPath: configPath) { socketPath in
      try Self.runEars(
        ["status", "--config", configPath, "--json", "--verbose"],
        environment: ["EARS_SOCKET_PATH": socketPath])
    }
    #expect(run.socketBecameReady)
    #expect(run.result.exitCode == 0)
    // The trace goes to stderr only; stdout stays the command's real output.
    #expect(run.result.stdout.contains("\"uptime_s\""))
    #expect(!run.result.stdout.contains("ears[debug]"))
    #expect(run.result.stderr.contains("ears[debug]: resolved control socket path:"))
    #expect(run.result.stderr.contains("ears[debug]: sending request: status"))
    #expect(run.result.stderr.contains("ears[debug]: received result:"))
  }

  @Test("ears session list returns an empty list from a fresh live earsd")
  func earsSessionListAgainstLiveDaemon() throws {
    let temp = TempDirectory()
    let configPath = temp.write(
      """
      data_root = "\(temp.url.path)/data"

      [earsd]
      source = []
      """,
      named: "config.toml"
    )

    let run = try Self.withRunningDaemon(configPath: configPath) { socketPath in
      try Self.runEars(
        ["session", "list", "--config", configPath, "--json"],
        environment: ["EARS_SOCKET_PATH": socketPath])
    }
    #expect(run.socketBecameReady)
    #expect(run.result.exitCode == 0)
    #expect(run.result.stdout.contains("\"sessions\":[]"))
  }

  @Test("ears status exits non-zero with a clear message when no daemon is reachable")
  func earsStatusNoDaemon() throws {
    let temp = TempDirectory()
    let configPath = temp.write(
      "data_root = \"\(temp.url.path)/data\"",
      named: "config.toml"
    )
    let socketPath = Self.tempSocketPath()

    let result = try Self.runEars(
      ["status", "--config", configPath],
      environment: ["EARS_SOCKET_PATH": socketPath])
    #expect(result.exitCode != 0)
    #expect(result.stderr.contains("could not reach earsd"))
  }

  // MARK: - ears: sources add/remove, capture pause/resume, flush (live earsd)

  @Test("ears sources add sends sources.add and surfaces the not-yet-supported failure")
  func earsSourcesAddAgainstLiveDaemon() throws {
    let temp = TempDirectory()
    let configPath = temp.write(
      """
      data_root = "\(temp.url.path)/data"

      [earsd]
      source = []
      """,
      named: "config.toml"
    )

    let run = try Self.withRunningDaemon(configPath: configPath) { socketPath in
      try Self.runEars(
        ["sources", "add", "mic", "--class", "mic", "--config", configPath, "--json"],
        environment: ["EARS_SOCKET_PATH": socketPath])
    }
    #expect(run.socketBecameReady)
    // ControlServer's locked decision: sources.add always fails in this
    // build (Phase 4 seam) -- this proves the CLI reaches the daemon and
    // surfaces that failure rather than silently accepting it.
    #expect(run.result.exitCode != 0)
    #expect(run.result.stderr.contains("sources.add is not supported"))
  }

  @Test("ears sources add rejects an unrecognized --class before it reaches the socket")
  func earsSourcesAddRejectsUnknownClass() throws {
    let temp = TempDirectory()
    let configPath = temp.write(
      """
      data_root = "\(temp.url.path)/data"

      [earsd]
      source = []
      """,
      named: "config.toml"
    )

    let result = try Self.runEars([
      "sources", "add", "mic", "--class", "bogus", "--config", configPath,
    ])
    #expect(result.exitCode != 0)
    #expect(result.stderr.contains("'bogus' is not a recognised source class"))
  }

  @Test("ears sources remove reports an unknown source clearly against a live earsd")
  func earsSourcesRemoveAgainstLiveDaemon() throws {
    let temp = TempDirectory()
    let configPath = temp.write(
      """
      data_root = "\(temp.url.path)/data"

      [earsd]
      source = []
      """,
      named: "config.toml"
    )

    let run = try Self.withRunningDaemon(configPath: configPath) { socketPath in
      try Self.runEars(
        ["sources", "remove", "mic", "--config", configPath, "--json"],
        environment: ["EARS_SOCKET_PATH": socketPath])
    }
    #expect(run.socketBecameReady)
    #expect(run.result.exitCode != 0)
    #expect(run.result.stderr.contains("unknown source 'mic'"))
  }

  @Test("ears capture pause with no source pauses every source (a no-op against zero sources)")
  func earsCapturePauseAllAgainstLiveDaemon() throws {
    let temp = TempDirectory()
    let configPath = temp.write(
      """
      data_root = "\(temp.url.path)/data"

      [earsd]
      source = []
      """,
      named: "config.toml"
    )

    let run = try Self.withRunningDaemon(configPath: configPath) { socketPath in
      try Self.runEars(
        ["capture", "pause", "--config", configPath, "--json"],
        environment: ["EARS_SOCKET_PATH": socketPath])
    }
    #expect(run.socketBecameReady)
    #expect(run.result.exitCode == 0)
    #expect(run.result.stdout.contains("{}"))
  }

  @Test("ears capture resume with an explicit unknown source reports the failure clearly")
  func earsCaptureResumeUnknownSourceAgainstLiveDaemon() throws {
    let temp = TempDirectory()
    let configPath = temp.write(
      """
      data_root = "\(temp.url.path)/data"

      [earsd]
      source = []
      """,
      named: "config.toml"
    )

    let run = try Self.withRunningDaemon(configPath: configPath) { socketPath in
      try Self.runEars(
        ["capture", "resume", "mic", "--config", configPath, "--json"],
        environment: ["EARS_SOCKET_PATH": socketPath])
    }
    #expect(run.socketBecameReady)
    #expect(run.result.exitCode != 0)
    #expect(run.result.stderr.contains("unknown source 'mic'"))
  }

  // MARK: - ears: sessions + session show (disk-backed pipeline views)

  /// Writes a minimal, valid schema-3 `session.toml` under
  /// `<dataRoot>/sessions/<id>/` — the fixture the daemon-free session
  /// surfaces read.
  private static func writeSessionFixture(
    dataRoot: URL, id: String, title: String,
    started: String = "2026-08-17T15:01:00Z", ended: String = "2026-08-17T15:32:00Z",
    warnings: [String] = []
  ) throws {
    let directory = dataRoot.appendingPathComponent("sessions").appendingPathComponent(id)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let warningLines = warnings.map { "\"\($0)\"" }.joined(separator: ", ")
    let toml = """
      schema = 3
      id = "\(id)"
      title = "\(title)"
      state = "ended"
      started = "\(started)"
      ended = "\(ended)"
      trigger = "manual"
      sources = ["mic"]
      interval = []
      attendee = []
      warnings = [\(warningLines)]
      """
    try toml.write(
      to: directory.appendingPathComponent("session.toml"), atomically: true, encoding: .utf8)
  }

  @Test("ears sessions --all lists disk sessions with a pipeline outcome, daemon-free")
  func earsSessionsAllListsDiskSessions() throws {
    let temp = TempDirectory()
    let dataRoot = temp.url.appendingPathComponent("data")
    let configPath = temp.write("data_root = \"\(dataRoot.path)\"", named: "config.toml")
    try Self.writeSessionFixture(
      dataRoot: dataRoot, id: "3db61b03-aaaa-bbbb-cccc-ddddeeeeffff", title: "Matt Silva")

    let human = try Self.runEars(["sessions", "--all", "--config", configPath])
    #expect(human.exitCode == 0)
    #expect(human.stdout.contains("Matt Silva"))
    // The id is on the row, so it can be handed to `session show` / `--session`.
    #expect(human.stdout.contains("3db61b03-aaaa-bbbb-cccc-ddddeeeeffff"))
    // An old session with no transcript reads as a neutral gap, not a crash.
    #expect(human.stdout.contains("– no transcript"))

    // The machine surface keeps `session list`'s payload shape.
    let json = try Self.runEars(["sessions", "--all", "--json", "--config", configPath])
    #expect(json.exitCode == 0)
    #expect(json.stdout.contains("\"sessions\":["))
    #expect(json.stdout.contains("\"id\":\"3db61b03-aaaa-bbbb-cccc-ddddeeeeffff\""))
  }

  @Test("ears sessions --json against a live daemon keeps the pinned empty-list shape")
  func earsSessionsAgainstLiveDaemon() throws {
    let temp = TempDirectory()
    let configPath = temp.write(
      """
      data_root = "\(temp.url.path)/data"

      [earsd]
      source = []
      """,
      named: "config.toml"
    )

    let run = try Self.withRunningDaemon(configPath: configPath) { socketPath in
      try Self.runEars(
        ["sessions", "--config", configPath, "--json"],
        environment: ["EARS_SOCKET_PATH": socketPath])
    }
    #expect(run.socketBecameReady)
    #expect(run.result.exitCode == 0)
    #expect(run.result.stdout.contains("\"sessions\":[]"))
  }

  @Test("ears session show resolves an id prefix and renders the five-stage view from disk")
  func earsSessionShowHappyPath() throws {
    let temp = TempDirectory()
    let dataRoot = temp.url.appendingPathComponent("data")
    let configPath = temp.write("data_root = \"\(dataRoot.path)\"", named: "config.toml")
    try Self.writeSessionFixture(
      dataRoot: dataRoot, id: "3db61b03-aaaa-bbbb-cccc-ddddeeeeffff", title: "Matt Silva",
      warnings: ["remote audio was lost for a stretch", "one track went unattributed"])

    let result = try Self.runEars(["session", "show", "3db6", "--config", configPath])
    #expect(result.exitCode == 0)
    #expect(result.stdout.contains("Matt Silva — ended"))
    #expect(result.stdout.contains(", 31m"))
    for stage in ["capture", "transcribe", "cleanup", "summarize", "note"] {
      #expect(result.stdout.contains(stage))
    }
    #expect(result.stdout.contains("⚠ 2 attribution warnings — show with --warnings"))

    let verbose = try Self.runEars(
      ["session", "show", "3db6", "--warnings", "--config", configPath])
    #expect(verbose.exitCode == 0)
    #expect(verbose.stdout.contains("⚠ remote audio was lost for a stretch"))
    #expect(!verbose.stdout.contains("--warnings"))
  }

  @Test("ears session show --json emits the pinned pipeline document")
  func earsSessionShowJSON() throws {
    let temp = TempDirectory()
    let dataRoot = temp.url.appendingPathComponent("data")
    let configPath = temp.write("data_root = \"\(dataRoot.path)\"", named: "config.toml")
    try Self.writeSessionFixture(
      dataRoot: dataRoot, id: "3db61b03-aaaa-bbbb-cccc-ddddeeeeffff", title: "Matt Silva",
      warnings: ["w1"])

    let result = try Self.runEars(
      ["session", "show", "matt", "--json", "--config", configPath])
    #expect(result.exitCode == 0)
    let data = try #require(result.stdout.data(using: .utf8))
    let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let object = try #require(parsed)
    #expect(object["schema"] as? Int == 1)
    #expect((object["session"] as? [String: Any])?["id"] as? String != nil)
    let stages = try #require(object["stages"] as? [[String: Any]])
    #expect(
      stages.map { $0["stage"] as? String }
        == ["capture", "transcribe", "cleanup", "summarize", "note"])
    #expect(object["warnings"] as? [String] == ["w1"])
    #expect(object["artifacts"] is [String: Any])
  }

  @Test("ears session show reports ambiguous and unknown refs clearly, exiting non-zero")
  func earsSessionShowBadRefs() throws {
    let temp = TempDirectory()
    let dataRoot = temp.url.appendingPathComponent("data")
    let configPath = temp.write("data_root = \"\(dataRoot.path)\"", named: "config.toml")
    try Self.writeSessionFixture(
      dataRoot: dataRoot, id: "3db61b03-aaaa-bbbb-cccc-ddddeeeeffff", title: "Matt Silva")
    try Self.writeSessionFixture(
      dataRoot: dataRoot, id: "9c00aaaa-bbbb-cccc-dddd-eeeeffff0000", title: "Matt Chen",
      started: "2026-08-16T10:00:00Z", ended: "2026-08-16T10:30:00Z")

    let ambiguous = try Self.runEars(["session", "show", "matt", "--config", configPath])
    #expect(ambiguous.exitCode != 0)
    #expect(ambiguous.stderr.contains("'matt' matches 2 sessions"))
    #expect(ambiguous.stderr.contains("Matt Silva"))
    #expect(ambiguous.stderr.contains("Matt Chen"))

    let unknown = try Self.runEars(["session", "show", "zzz", "--config", configPath])
    #expect(unknown.exitCode != 0)
    #expect(unknown.stderr.contains("no session matches 'zzz'"))
  }

  @Test("ears session trace walks track to label from a fixture dir and writes nothing")
  func earsSessionTraceReadsFixture() throws {
    let temp = TempDirectory()
    let dataRoot = temp.url.appendingPathComponent("data")
    let configPath = temp.write("data_root = \"\(dataRoot.path)\"", named: "config.toml")
    let id = "46aa6491-aaaa-bbbb-cccc-ddddeeeeffff"
    let directory = dataRoot.appendingPathComponent("sessions").appendingPathComponent(id)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let files = [
      "session.toml": """
      schema = 3
      id = "\(id)"
      title = "Jitsi Room"
      platform = "jitsi"
      external_id = "meet.jit.si/room"
      state = "ended"
      started = "2026-11-22T17:00:37Z"
      ended = "2026-11-22T17:00:59Z"
      trigger = "browser-extension"
      sources = ["mic", "browser:jitsi:t1"]
      interval = []
      warnings = []

      [[attendee]]
      id = "4494e60c"
      display_name = "a"
      origin = "platform"
      self = false
      source = "browser:jitsi:t1"

      [[speaker]]
      source = "browser:jitsi:t1"
      name = "a"
      confidence = "correlated"
      """,
      "attribution.jsonl": """
      {"schema":1,"type":"admitted","t":1,"trackId":"a54dcf0b-c99f-4bce-bc67-c75eeb31ea7d","participantId":"t1","generation":1}
      {"schema":1,"type":"identity-link","t":2,"trackId":"a54dcf0b-c99f-4bce-bc67-c75eeb31ea7d","captureId":"t1","participantId":"4494e60c"}
      {"schema":1,"type":"audio-onset","t":3,"participantId":"t1","trackId":"a54dcf0b-c99f-4bce-bc67-c75eeb31ea7d","state":"start","framePeak":0.1}

      """,
      "transcript.json": """
      {"schema":1,"segments":[{"start":0,"end":1,"source":"browser:jitsi:t1","speaker":"a","text":"Okay. How about that?"}]}
      """,
    ]
    for (name, text) in files {
      try text.write(
        to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    let before = try files.keys.map { try Data(contentsOf: directory.appendingPathComponent($0)) }

    let result = try Self.runEars(["session", "trace", "46aa", "--config", configPath])
    #expect(result.exitCode == 0)
    #expect(
      result.stdout.contains("a54dcf0b  -> t1  -> 4494e60c  -> 'a'  -> 'a'  (browser:jitsi:t1)"))
    #expect(result.stdout.contains("browser:jitsi:t1  'a'  4"))
    #expect(result.stdout.contains("no attendee has self=true"))

    let after = try files.keys.map { try Data(contentsOf: directory.appendingPathComponent($0)) }
    #expect(before == after)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        == files.keys.sorted())
  }

  @Test("ears flush finalizes every source's in-progress chunk (a no-op against zero sources)")
  func earsFlushAgainstLiveDaemon() throws {
    let temp = TempDirectory()
    let configPath = temp.write(
      """
      data_root = "\(temp.url.path)/data"

      [earsd]
      source = []
      """,
      named: "config.toml"
    )

    let run = try Self.withRunningDaemon(configPath: configPath) { socketPath in
      try Self.runEars(
        ["flush", "--config", configPath, "--json"],
        environment: ["EARS_SOCKET_PATH": socketPath])
    }
    #expect(run.socketBecameReady)
    #expect(run.result.exitCode == 0)
    #expect(run.result.stdout.contains("{}"))
  }
}

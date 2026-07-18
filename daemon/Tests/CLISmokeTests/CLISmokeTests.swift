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
      id = "system"
      class = "system"
      """,
      named: "config.toml"
    )

    let run = try Self.withRunningDaemon(configPath: configPath) { _ in }
    #expect(run.socketBecameReady)
    #expect(run.exitCode == 0)
    #expect(run.stderr.contains("skipping source 'mic'"))
    #expect(run.stderr.contains("disabled in config"))
    #expect(run.stderr.contains("skipping source 'system'"))
    #expect(run.stderr.contains("Phase 1"))
    #expect(run.stderr.contains("resolved sources: (none)"))
    #expect(run.stderr.contains("SIGTERM received"))
    #expect(run.stderr.contains("stopped"))
  }

  @Test(
    "a normal run with ALLEARS_CAPTURE_BACKEND=synthetic and one enabled mic source writes real chunk files and a chunk index event to disk"
  )
  func normalRunWithSyntheticBackendWritesRealFilesToDisk() throws {
    // Unlike every other test in this file, this one *does* declare an
    // enabled mic-class source -- safe only because
    // `ALLEARS_CAPTURE_BACKEND=synthetic` (set below, in the spawned
    // process's own environment) diverts `RealCaptureBackendFactory` to a
    // scripted `SyntheticCaptureBackend` for every source (see that file's
    // doc comment -- and note it is deliberately not `EARS_`-prefixed,
    // since that prefix gets swept into real layered config and rejected as
    // an unknown key), so this still never touches Core Audio or prompts
    // TCC. This is the one test in this file that proves a real, spawned
    // `earsd` binary actually writes chunk files and index entries to disk
    // -- every other test here uses zero/disabled sources, so nothing else
    // exercises that path end-to-end.
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

    let run = try Self.withRunningDaemon(
      configPath: configPath,
      environment: ["ALLEARS_CAPTURE_BACKEND": "synthetic"]
    ) { _ in }
    #expect(run.socketBecameReady)
    #expect(run.exitCode == 0)

    let sourceDirectory = URL(fileURLWithPath: dataRootPath)
      .appendingPathComponent("sources").appendingPathComponent("mic")
    let chunkFileNames =
      ((try? FileManager.default.contentsOfDirectory(
        atPath: sourceDirectory.appendingPathComponent("chunks").path)) ?? [])
      + ((try? FileManager.default.contentsOfDirectory(
        atPath: sourceDirectory.appendingPathComponent("asr").path)) ?? [])
    #expect(!chunkFileNames.isEmpty, "expected at least one chunk file under chunks/ or asr/")

    let indexContents =
      (try? String(
        contentsOfFile: sourceDirectory.appendingPathComponent("index.jsonl").path,
        encoding: .utf8)) ?? ""
    let indexLines = indexContents.split(separator: "\n", omittingEmptySubsequences: true)
    let hasChunkEvent = indexLines.contains { line in
      guard let data = line.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return false }
      // index.jsonl discriminates its event kind on the "t" field, per
      // docs/data-formats.md's "The index (index.jsonl)" section -- distinct
      // from the structured-log JSON Lines format's "event" field asserted
      // on elsewhere in this file.
      return object["t"] as? String == "chunk"
    }
    #expect(hasChunkEvent, "expected a 't':'chunk' event in index.jsonl:\n\(indexContents)")
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

  @Test("ears with no subcommand is a pure dispatcher: it prints help, not a stub run")
  func earsRootIsAPureDispatcher() throws {
    let result = try Self.runEars([])
    // ArgumentParser's default run() for a command that declares
    // subcommands but no behavior of its own is a help request, so the
    // subcommand list must be shown and no former root flag may survive.
    let output = result.stdout + result.stderr
    #expect(output.contains("SUBCOMMANDS"))
    #expect(output.contains("config"))
    #expect(output.contains("status"))
    #expect(!output.contains("--print-config"))
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

  @Test("ears session open fails clearly against a live earsd when no source is given")
  func earsSessionOpenNoSources() throws {
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
        ["session", "open", "--slug", "standup", "--config", configPath],
        environment: ["EARS_SOCKET_PATH": socketPath])
    }
    #expect(run.socketBecameReady)
    #expect(run.result.exitCode != 0)
    #expect(run.result.stderr.contains("at least one source is required"))
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
    #expect(run.result.stderr.contains("ears[debug]: sending request: {\"cmd\":\"status\"}"))
    #expect(run.result.stderr.contains("ears[debug]: received reply:"))
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
}

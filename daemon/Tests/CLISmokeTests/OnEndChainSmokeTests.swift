import EarsCore
import EarsDataStore
import EarsIPC
import Foundation
import Testing

/// Tier-3, end-to-end coverage for the daemon's `--json` on-end chain (issue
/// #64): a real spawned `earsd` whose session-end hook spawns the real
/// `transcribe`/`cleanup`/`summarize` binaries in `--json` mode, with their
/// result envelopes actually parsed by `OnClosePipelineRunner` — the
/// EarsDaemon-level proof the scripted-runner unit tests can't give.
///
/// Hermetic like the contract harnesses: no mic (`[earsd] source = []`), the
/// ASR diverted to `NullTranscriber` via `ALLEARS_TRANSCRIBE_BACKEND=null`
/// (inherited by the spawned `transcribe`), and a scripted `[llm] command`
/// for the LLM stages. The stage binaries are resolved from the build
/// products directory via the daemon's `PATH` — the same `/usr/bin/env`
/// resolution production uses. The browser-extension trigger (the only kind
/// that fires the hook) is driven over the real control socket with
/// `EarsIPC.ControlSocketClient`, since `ears` deliberately has no flag for
/// it.
@Suite("CLI Smoke: on-end --json chain")
struct OnEndChainSmokeTests {
  private final class BundleMarker {}

  /// The build products directory — where `earsd` and the stage binaries all
  /// live as siblings of the test bundle (see `CLISmokeTests.binaryURL`).
  private static func productsDirectory() throws -> URL {
    Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent()
  }

  private static func binaryURL(_ name: String) throws -> URL {
    let url = try productsDirectory().appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw SetupError.binaryNotFound(url.path)
    }
    return url
  }

  private enum SetupError: Error, CustomStringConvertible {
    case binaryNotFound(String)
    var description: String {
      switch self {
      case .binaryNotFound(let path):
        return "expected a built binary at \(path) -- run `swift build` before `swift test`"
      }
    }
  }

  /// A temp directory that cleans itself up on teardown.
  private final class TempDirectory {
    let url: URL

    init() {
      url = FileManager.default.temporaryDirectory
        .appendingPathComponent("OnEndChainSmoke-\(UUID().uuidString)", isDirectory: true)
      try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func write(_ contents: String, named name: String) -> String {
      let fileURL = url.appendingPathComponent(name)
      try? contents.write(to: fileURL, atomically: true, encoding: .utf8)
      return fileURL.path
    }

    deinit { try? FileManager.default.removeItem(at: url) }
  }

  /// The scripted `[llm] command`: drains stdin, prints a fixed line —
  /// deterministic and network-free (mirrors `PlainModeContractSmokeTests`).
  private static func writeFakeLLMScript(in temp: TempDirectory) throws -> String {
    let scriptURL = temp.url.appendingPathComponent("fake-llm.sh")
    // Two prompts reach this script per session: the `--select-preset`
    // classification call, answered with the one configured preset, and the
    // preset's own summary call. Telling them apart here is what makes the
    // chain's selection step real end to end rather than exercising the
    // unknown-answer fallback by accident.
    let script = """
      #!/bin/sh
      prompt=$(/bin/cat)
      case "$prompt" in
        *"Choose exactly one of these presets"*)
          printf 'preset: brief\\nbecause: the fixture session is a call.' ;;
        *)
          printf '%s' 'scripted summary line' ;;
      esac
      """
    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    return scriptURL.path
  }

  /// Every file under `root` (recursively) whose name ends in `suffix`.
  private static func files(withSuffix suffix: String, under root: String) -> [String] {
    guard let enumerator = FileManager.default.enumerator(atPath: root) else { return [] }
    return enumerator.compactMap { $0 as? String }
      .filter { $0.hasSuffix(suffix) }
      .map { root + "/" + $0 }
  }

  @Test(
    "ending a browser-triggered session runs the real transcribe → cleanup → summarize chain over --json envelopes",
    .timeLimit(.minutes(2)))
  func onEndChainRunsRealStagesWithJSONEnvelopes() async throws {
    let temp = TempDirectory()
    let dataRoot = temp.url.appendingPathComponent("data").path
    let outputRoot = temp.url.appendingPathComponent("out").path
    let daemonLogPath = temp.url.appendingPathComponent("earsd.jsonl").path
    let stageLogPath = temp.url.appendingPathComponent("stages.jsonl").path
    // `sun_path` caps at 104 bytes, so /tmp — not the temp dir — per the
    // package-wide precedent.
    let socketPath = "/tmp/ears-onend-\(UUID().uuidString.prefix(8)).sock"
    defer { try? FileManager.default.removeItem(atPath: socketPath) }
    let scriptPath = try Self.writeFakeLLMScript(in: temp)
    let configPath = temp.write(
      """
      data_root = "\(dataRoot)"
      output_root = "\(outputRoot)"
      socket_path = "\(socketPath)"

      [log]
      file = "\(stageLogPath)"

      [earsd]
      source = []

      [earsd.sessions]
      on_end_stages = ["transcribe", "cleanup", "summarize"]
      rejoin_hold_s = 0
      # `NullTranscriber` renders a wordless transcript, which the
      # empty-transcript gate would (correctly) stop the chain on. Both
      # thresholds at 0 disable the gate — the pre-gate behaviour this test
      # exercises the full chain under.
      min_words = 0
      min_speech_seconds = 0

      [llm]
      backend = "command"
      command = "\(scriptPath)"

      [[summarize.preset]]
      name = "brief"
      when = "any conversation this fixture captures"
      """,
      named: "config.toml")

    // The daemon's environment is the stage children's environment:
    // - PATH resolves the real built stage binaries (plus /usr/bin/env's
    //   needs) exactly the way production spawns them;
    // - EARS_CONFIG points the children (spawned without --config) at the
    //   same config file;
    // - the ALLEARS seam keeps transcribe model-free.
    let environment = [
      "PATH": "\(try Self.productsDirectory().path):/usr/bin:/bin",
      "EARS_CONFIG": configPath,
      "ALLEARS_TRANSCRIBE_BACKEND": "null",
    ]

    let daemon = Process()
    daemon.executableURL = try Self.binaryURL("earsd")
    daemon.arguments = ["--config", configPath, "--log-file", daemonLogPath]
    daemon.environment = environment
    daemon.standardOutput = Pipe()
    let stderrPipe = Pipe()
    daemon.standardError = stderrPipe
    try daemon.run()
    defer {
      daemon.terminate()
      daemon.waitUntilExit()
    }

    // Wait for the control socket — proof `EarsDaemon.start()` finished.
    var socketReady = false
    for _ in 0..<250 {
      if FileManager.default.fileExists(atPath: socketPath) {
        socketReady = true
        break
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    try #require(socketReady, "earsd's control socket never appeared at \(socketPath)")

    // Drive a browser-triggered session — the only trigger that fires the
    // on-end hook — over the real control socket.
    let client = try await ControlSocketClient.connect(toPath: socketPath)
    try await client.hello(client: "on-end-chain-smoke")
    let session = try await client.send(
      .sessionStart(
        SessionStartParams(
          platform: "meet", externalID: "onend-e2e", sources: ["mic"],
          trigger: .browserExtension)),
      expecting: Session.self)
    #expect(session.trigger == .browserExtension)
    // Session timestamps persist at second resolution: a sub-second session
    // round-trips to an empty interval, which `transcribe --session` rejects
    // ("no non-empty intervals"). Let the session live past the boundary.
    try await Task.sleep(for: .milliseconds(1_500))
    let ended = try await client.send(.sessionEnd(session: session.id), expecting: Session.self)
    #expect(ended.state == .ended)
    await client.close()

    // The chain runs in its own task after session.end returns; poll the
    // daemon log for its terminal line (summarize's per-preset summary).
    var daemonLog = ""
    for _ in 0..<600 {
      daemonLog = (try? String(contentsOfFile: daemonLogPath, encoding: .utf8)) ?? ""
      if daemonLog.contains("summarize wrote 1/1 presets") { break }
      try await Task.sleep(for: .milliseconds(100))
    }

    // Every stage was spawned in --json mode and succeeded — the envelopes
    // really were parsed (a parse failure would log "exited 0 but failed"
    // and stop the chain before summarize).
    #expect(
      daemonLog.contains("spawning transcribe --session \(session.id) --json"),
      "expected the transcribe spawn line with --json; daemon log:\n\(daemonLog)")
    for stage in ["transcribe", "cleanup", "summarize"] {
      #expect(
        daemonLog.contains("\(stage) succeeded for session '\(session.id)'"),
        "expected \(stage) to succeed; daemon log:\n\(daemonLog)")
    }
    #expect(
      daemonLog.contains("summarize wrote 1/1 presets for session '\(session.id)'"),
      "expected the per-preset summary line; daemon log:\n\(daemonLog)")
    // Which preset this session got, and why, reached the daemon log — the
    // chain selects one preset per session rather than running them all.
    #expect(
      daemonLog.contains("spawning summarize") && daemonLog.contains("--select-preset --json"),
      "expected summarize to be spawned with --select-preset; daemon log:\n\(daemonLog)")
    #expect(
      daemonLog.contains("selected preset 'brief': the fixture session is a call."),
      "expected the selected preset and its reasoning; daemon log:\n\(daemonLog)")
    #expect(!daemonLog.contains("exited 0 but failed"))
    #expect(!daemonLog.contains("schema mismatch"))

    // The chain's artifacts exist on disk: each stage's envelope named a real
    // file that fed the next stage.
    // The raw transcript is an intermediate: it lands in the session's own
    // data-store directory, never under `output_root`.
    #expect(
      !Self.files(withSuffix: "sessions/\(session.id)/transcript.md", under: dataRoot).isEmpty,
      "expected the session's raw transcript under \(dataRoot)")
    // The cleaned transcript and the summaries are the *published* artifacts:
    // they land under `output_root`, where `[cleanup] output`'s template puts
    // them — never in the data store.
    #expect(
      !Self.files(withSuffix: ".md", under: outputRoot).isEmpty,
      "expected a published cleaned transcript under \(outputRoot)")
    #expect(
      !Self.files(withSuffix: ".summary.md", under: outputRoot).isEmpty,
      "expected a .summary.md under \(outputRoot)")
    #expect(
      Self.files(withSuffix: ".clean.md", under: dataRoot).isEmpty,
      "the data store must hold intermediates only, never a published clean transcript")
  }

  @Test(
    "an empty session stops after transcribe, still stamps transcript-completion, and publishes nothing",
    .timeLimit(.minutes(2)))
  func emptySessionSkipsTheLLMStages() async throws {
    let temp = TempDirectory()
    let dataRoot = temp.url.appendingPathComponent("data").path
    let outputRoot = temp.url.appendingPathComponent("out").path
    let daemonLogPath = temp.url.appendingPathComponent("earsd.jsonl").path
    let stageLogPath = temp.url.appendingPathComponent("stages.jsonl").path
    let socketPath = "/tmp/ears-onend-empty-\(UUID().uuidString.prefix(8)).sock"
    defer { try? FileManager.default.removeItem(atPath: socketPath) }
    let scriptPath = try Self.writeFakeLLMScript(in: temp)
    // The gate's shipped defaults, stated rather than assumed — this is the
    // configuration the two 2026-08-20 sessions ran under.
    let configPath = temp.write(
      """
      data_root = "\(dataRoot)"
      output_root = "\(outputRoot)"
      socket_path = "\(socketPath)"

      [log]
      file = "\(stageLogPath)"

      [earsd]
      source = []

      [earsd.sessions]
      on_end_stages = ["transcribe", "cleanup", "summarize"]
      rejoin_hold_s = 0
      min_words = 10
      min_speech_seconds = 5

      [llm]
      backend = "command"
      command = "\(scriptPath)"

      [[summarize.preset]]
      name = "brief"
      when = "any conversation this fixture captures"
      """,
      named: "config.toml")

    let environment = [
      "PATH": "\(try Self.productsDirectory().path):/usr/bin:/bin",
      "EARS_CONFIG": configPath,
      // NullTranscriber: a real transcript document with nothing said in it —
      // exactly the shape a session of background audio produces.
      "ALLEARS_TRANSCRIBE_BACKEND": "null",
    ]
    let daemon = Process()
    daemon.executableURL = try Self.binaryURL("earsd")
    daemon.arguments = ["--config", configPath, "--log-file", daemonLogPath]
    daemon.environment = environment
    daemon.standardOutput = Pipe()
    daemon.standardError = Pipe()
    try daemon.run()
    defer {
      daemon.terminate()
      daemon.waitUntilExit()
    }

    var socketReady = false
    for _ in 0..<250 {
      if FileManager.default.fileExists(atPath: socketPath) {
        socketReady = true
        break
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    try #require(socketReady, "earsd's control socket never appeared at \(socketPath)")

    let client = try await ControlSocketClient.connect(toPath: socketPath)
    try await client.hello(client: "on-end-empty-smoke")
    let session = try await client.send(
      .sessionStart(
        SessionStartParams(
          platform: "meet", externalID: "onend-empty", sources: ["mic"],
          trigger: .browserExtension)),
      expecting: Session.self)
    try await Task.sleep(for: .milliseconds(1_500))
    _ = try await client.send(.sessionEnd(session: session.id), expecting: Session.self)
    await client.close()

    var daemonLog = ""
    for _ in 0..<600 {
      daemonLog = (try? String(contentsOfFile: daemonLogPath, encoding: .utf8)) ?? ""
      if daemonLog.contains("skipping cleanup, summarize") { break }
      try await Task.sleep(for: .milliseconds(100))
    }

    // One line, naming the reason and the numbers against the thresholds.
    #expect(
      daemonLog.contains(
        "skipping cleanup, summarize for session '\(session.id)': transcript is empty"),
      "expected the skip line; daemon log:\n\(daemonLog)")
    #expect(daemonLog.contains("thresholds 10 words / 5.0s"))
    // transcribe ran; the LLM stages were never spawned.
    #expect(daemonLog.contains("transcribe succeeded for session '\(session.id)'"))
    #expect(!daemonLog.contains("spawning cleanup"))
    #expect(!daemonLog.contains("spawning summarize"))

    // The raw transcript is still the durable artifact...
    let transcripts = Self.files(
      withSuffix: "sessions/\(session.id)/transcript.md", under: dataRoot)
    #expect(!transcripts.isEmpty, "expected the session's raw transcript under \(dataRoot)")
    // ...and the retention clock still started: a skipped chain is a
    // successful one, so audio ages out exactly as it did before the gate.
    var completed: Instant?
    for _ in 0..<100 {
      completed =
        (try? SessionStore.read(
          sessionID: session.id, dataRoot: URL(fileURLWithPath: dataRoot)))?.transcriptCompleted
      if completed != nil { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(completed != nil, "expected transcript_completed to be stamped for a skipped chain")

    // Nothing reached the vault: no published clean transcript, no summary,
    // no note written over anything.
    #expect(
      Self.files(withSuffix: ".md", under: outputRoot).isEmpty,
      "a skipped chain must publish nothing under \(outputRoot)")
  }
}

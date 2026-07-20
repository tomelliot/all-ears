import EarsCore
import Foundation

/// Runs an on-close pipeline (`transcribe` → `cleanup` → `summarize`) against
/// a closed session — the stage-spawning logic ``AppSignalTriggerObserver``
/// originally owned, extracted so a session closed by the browser extension
/// (`trigger == .browserExtension`, see ``EarsDaemon``) can run the same
/// pipeline without an app-signal rule match.
///
/// Stops the chain — loudly — on the first unrecognised stage or non-zero
/// exit. Never silently continues past a failed stage as if the run
/// succeeded.
public struct OnClosePipelineRunner: Sendable {
  /// Runs one pipeline stage (`"transcribe"`, `"cleanup"`, `"summarize"`)
  /// with the given arguments and returns its exit code. The production
  /// runner spawns the real binary via `Foundation.Process` (PATH-resolved
  /// through `/usr/bin/env`, matching `EarsLLMKit.CommandLLMBackend`); tests
  /// inject a scripted fake.
  public typealias ProcessRunner = @Sendable (String, [String]) async -> Int32

  private let outputRoot: URL
  private let runProcess: ProcessRunner
  private let log: @Sendable (String) -> Void

  public init(
    outputRoot: URL,
    runProcess: @escaping ProcessRunner = OnClosePipelineRunner.realProcessRunner,
    log: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    self.outputRoot = outputRoot
    self.runProcess = runProcess
    self.log = log
  }

  /// Runs `stages` in order against the closed session. `context` names the
  /// initiator in log lines (a trigger rule's name, or e.g.
  /// `"browser-session-close"`).
  public func run(stages: [String], for descriptor: SessionDescriptor, context: String) async {
    for stage in stages {
      guard ["transcribe", "cleanup", "summarize"].contains(stage) else {
        log("\(context) on_close: unrecognised stage '\(stage)'; stopping the chain")
        return
      }
      let arguments = pipelineArguments(stage: stage, descriptor: descriptor)
      let exitCode = await runProcess(stage, arguments)
      guard exitCode == 0 else {
        log(
          "\(context) on_close: stage '\(stage)' failed (exit \(exitCode)) for "
            + "session '\(descriptor.id)'; stopping the chain"
        )
        return
      }
      log("\(context) on_close: stage '\(stage)' succeeded for session '\(descriptor.id)'")
    }
  }

  /// Runs a meeting-level transcribe against an ended meeting — the v2
  /// auto-transcription trigger (`transcribe --meeting <id>` unions the
  /// meeting's intervals into one transcript; see
  /// `docs/specs/control-protocol.md`'s "Transcription output").
  /// Only the transcribe stage runs at meeting level today; `cleanup`/
  /// `summarize` chains stay session-path-based.
  public func runMeetingTranscribe(meetingID: String, context: String) async {
    let exitCode = await runProcess("transcribe", ["--meeting", meetingID])
    if exitCode == 0 {
      log("\(context) on_end: transcribe succeeded for meeting '\(meetingID)'")
    } else {
      log("\(context) on_end: transcribe failed (exit \(exitCode)) for meeting '\(meetingID)'")
    }
  }

  /// Builds each stage's argv. `transcribe` resolves the session directly;
  /// `cleanup`/`summarize` are handed the file path the *previous* stage is
  /// expected to have written, per `docs/specs/llm-stages.md`'s
  /// composition example (`transcribe --session "$SID" && cleanup
  /// "$OUT/....transcript.md" && summarize "$OUT/....clean.md"`).
  ///
  /// **Known duplication:** the `<date>/<time>_<slug>.transcript.md` path
  /// shape mirrors `transcribe`'s own `OutputPathResolution` convention,
  /// restated here rather than shared, since that type lives in the
  /// `transcribe` executable target, not a library `EarsDaemonKit` can
  /// depend on. If that convention ever changes, this must change with it.
  private func pipelineArguments(stage: String, descriptor: SessionDescriptor) -> [String] {
    switch stage {
    case "transcribe":
      return ["--session", descriptor.id]
    case "cleanup":
      return [transcriptPath(for: descriptor).path]
    case "summarize":
      return [cleanedPath(for: descriptor).path, "--all-presets"]
    default:
      return []
    }
  }

  private func transcriptPath(for descriptor: SessionDescriptor) -> URL {
    let timestamp = FilenameTimestampCodec.string(for: descriptor.start)
    let components = timestamp.split(separator: "T", maxSplits: 1)
    let date = String(components[0])
    let time = String(components[1].dropLast())  // drop trailing "Z"
    return
      outputRoot
      .appendingPathComponent(date)
      .appendingPathComponent("\(time)_\(descriptor.slug).transcript.md")
  }

  private func cleanedPath(for descriptor: SessionDescriptor) -> URL {
    let transcript = transcriptPath(for: descriptor)
    let name = transcript.lastPathComponent
    guard name.hasSuffix(".transcript.md") else { return transcript }
    let stem = String(name.dropLast(".transcript.md".count))
    return transcript.deletingLastPathComponent().appendingPathComponent("\(stem).clean.md")
  }

  /// The production ``ProcessRunner``: spawns `name` (PATH-resolved via
  /// `/usr/bin/env`) with `arguments`, waits for exit, and returns its
  /// status.
  public static let realProcessRunner: ProcessRunner = { name, arguments in
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [name] + arguments
    do {
      try process.run()
    } catch {
      return -1
    }
    return await withCheckedContinuation { continuation in
      process.terminationHandler = { finished in
        continuation.resume(returning: finished.terminationStatus)
      }
    }
  }
}

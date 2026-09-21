import EarsCLISupport
import EarsCore
import Foundation
import Synchronization

/// The exit status and captured output of one spawned pipeline stage.
///
/// Carrying stderr — rather than letting the child inherit the daemon's own,
/// where it vanished — is what makes an on-end transcribe failure diagnosable
/// from the daemon log alone. All-ears issue #21: the failing run's "stderr was
/// captured nowhere, so the failing run's actual error message is
/// unrecoverable"; capturing it "alone would have identified the root cause on
/// day one".
///
/// stdout carries the stage's machine-readable result contract: the daemon
/// spawns every stage with `--json`, so a successful run's stdout is exactly
/// one JSON result-envelope document (``StageResultEnvelope``) whose `output`
/// the stage chain feeds to the next stage.
public struct SpawnOutcome: Sendable, Equatable {
  public var exitCode: Int32
  /// The child's stderr, verbatim. Callers bound it before logging via
  /// ``OnClosePipelineRunner/boundedCapture(_:)`` so a runaway child can't
  /// flood the daemon log. On a `--json` failure its last line is the error
  /// envelope (`ok: false`, `exit_class`, `message`).
  public var stderr: String
  /// The child's stdout, verbatim (the `--json` contract requires it to be
  /// exactly one JSON envelope document on success, byte-empty on failure —
  /// see ``StageResultEnvelope/decodeSuccessDocument(stdout:tool:)``).
  public var stdout: String

  public init(exitCode: Int32, stderr: String = "", stdout: String = "") {
    self.exitCode = exitCode
    self.stderr = stderr
    self.stdout = stdout
  }
}

/// One stage of the on-end pipeline, in chain order. The raw values are the
/// config vocabulary (`[earsd.sessions] on_end_stages`) *and* the spawned
/// binary names.
public enum OnEndStage: String, Sendable, Hashable, CaseIterable {
  case transcribe
  case cleanup
  case summarize

  /// Resolves the raw `on_end_stages` config list into a valid chain, with a
  /// human-readable problem per entry dropped. Pure and lenient, matching the
  /// per-source config policy ("skipped and reported, never takes down the
  /// daemon"):
  ///
  /// - Unknown stage names are dropped with a problem.
  /// - `cleanup`/`summarize` without `transcribe` are dropped with a problem —
  ///   the LLM stages consume the transcribe stage's output, so a chain
  ///   without it has nothing to run on.
  /// - Duplicates collapse; config order is irrelevant. The result is always
  ///   in canonical chain order (`allCases`).
  public static func resolveList(_ raw: [String]) -> (stages: [OnEndStage], problems: [String]) {
    var problems: [String] = []
    var requested = Set<OnEndStage>()
    for name in raw {
      guard let stage = OnEndStage(rawValue: name) else {
        problems.append(
          "unknown on_end_stages entry '\(name)' "
            + "(valid: \(allCases.map(\.rawValue).joined(separator: ", ")))")
        continue
      }
      requested.insert(stage)
    }
    if !requested.contains(.transcribe) && !requested.isEmpty {
      let dropped = allCases.filter { requested.contains($0) }.map(\.rawValue)
      problems.append(
        "on_end_stages \(dropped) require the transcribe stage; dropping the on-end chain")
      requested = []
    }
    return (allCases.filter { requested.contains($0) }, problems)
  }
}

/// Runs the on-end stage chain against an ended session — the stage-spawner
/// behind the session-end hook (see ``EarsDaemon``):
///
///     transcribe --session <id> --json      → envelope names the .transcript.md
///     cleanup <transcript path> --json      → envelope names the .clean.md
///     summarize <path> --all-presets --json → envelope names each preset's file
///
/// The daemon speaks the versioned `--json` result envelope to the stages
/// (issue #64 consuming issue #63's producer contract; humans keep plain
/// mode): each stage's stdout is exactly one JSON document whose `output`
/// feeds the next stage, so the daemon never re-derives `transcribe`'s
/// `OutputPathResolution` logic. The parse side is strict
/// (``StageResultEnvelope/decodeSuccessDocument(stdout:tool:)``): anything
/// that is not one decodable v1 envelope — pollution, a wrong major, `ok:
/// false` under exit 0 — is a contract violation that fails the stage, and
/// the envelope's `output` must exist on disk before it feeds the next stage
/// — a lie or stale path dies at this seam, not two stages later.
///
/// The chain stops loudly on the first failure. A `cleanup`/`summarize`
/// failure never un-succeeds the transcribe: the raw transcript is the
/// durable artifact, and the caller's retention stamp keys on transcribe
/// alone. On any non-zero exit the child's captured stderr lands in the
/// daemon log so the failure is diagnosable from the log alone (issue #21);
/// when its last line decodes as the error envelope, the envelope's
/// `exit_class`/`message` ride along — augmenting, never replacing, the
/// bounded raw capture.
public struct OnClosePipelineRunner: Sendable {
  /// Runs one pipeline stage binary (`"transcribe"`, `"cleanup"`,
  /// `"summarize"`) with the given arguments and returns its exit code plus
  /// captured stderr and stdout.
  /// The production runner spawns the real binary via `Foundation.Process`
  /// (PATH-resolved through `/usr/bin/env`, matching
  /// `EarsLLMKit.CommandLLMBackend`); tests inject a scripted fake.
  public typealias ProcessRunner = @Sendable (String, [String]) async -> SpawnOutcome

  private let runProcess: ProcessRunner
  private let log: @Sendable (String) -> Void

  public init(
    runProcess: @escaping ProcessRunner = OnClosePipelineRunner.realProcessRunner,
    log: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    self.runProcess = runProcess
    self.log = log
  }

  /// Runs the configured stage chain against an ended session.
  ///
  /// A session that recorded only background audio still transcribes — into
  /// a document with nothing in it — and the LLM stages downstream of that
  /// invent content from it and publish the invention. `emptiness` is the gate
  /// that stops the chain after transcribe when the fresh transcript's own
  /// frontmatter says there was nothing said; a skipped chain returns `true`
  /// exactly like a completed one.
  ///
  /// `recordIssues` receives every failure and `warning:` the stages
  /// reported, once, after the chain stops. A clean run hands it an empty
  /// list, so a rerun clears what an earlier run recorded.
  ///
  /// `recordNotes` receives the paths summarize wrote, once, and only when
  /// summarize succeeded: a failed rerun must not drop the claim an earlier
  /// run's note still holds, because the note is still on disk.
  ///
  /// - Returns: `true` iff `transcribe --session` exited 0 — the signal the
  ///   caller uses to stamp the session's transcript-completion marker (which
  ///   in turn starts the retention clock). LLM-stage failures are logged but
  ///   never affect the return value: derived artifacts must not hold the
  ///   retention clock hostage, and neither does an empty-transcript skip.
  @discardableResult
  public func runOnEndChain(
    sessionID: String, stages: [OnEndStage],
    emptiness: TranscriptEmptinessPolicy = .defaults,
    context: String,
    recordIssues: @Sendable ([PipelineIssue]) async -> Void = { _ in },
    recordNotes: @Sendable ([String]) async -> Void = { _ in }
  ) async -> Bool {
    // Config validation (`EarsdConfigSchema`) rejects LLM stages without
    // transcribe; an empty list means the whole chain is off. Defensive here
    // so a mis-wired caller degrades to a no-op, not a cleanup of nothing.
    guard stages.contains(.transcribe) else { return false }

    var issues: [PipelineIssue] = []
    var notes: [String]? = nil
    let transcribed = await runChain(
      sessionID: sessionID, stages: stages, emptiness: emptiness, context: context,
      issues: &issues, notes: &notes)
    await recordIssues(issues)
    if let notes { await recordNotes(notes) }
    return transcribed
  }

  private func runChain(
    sessionID: String, stages: [OnEndStage], emptiness: TranscriptEmptinessPolicy,
    context: String, issues: inout [PipelineIssue], notes: inout [String]?
  ) async -> Bool {
    guard
      let transcriptPath = await runPathStage(
        .transcribe, arguments: ["--session", sessionID, "--json"], sessionID: sessionID,
        context: context, issues: &issues)
    else { return false }

    // The empty-transcript gate. transcribe has written
    // `sessions/<id>/transcript.md` and its frontmatter carries the two
    // measurements the decision needs, so nothing here re-derives what the
    // stage already counted.
    let downstream = stages.filter { $0 != .transcribe }
    if !downstream.isEmpty, emptiness.isEnabled,
      let verdict = emptinessVerdict(
        transcriptPath: transcriptPath, policy: emptiness, sessionID: sessionID, context: context),
      verdict.isEmpty
    {
      log(
        "\(context) on_end: skipping \(downstream.map(\.rawValue).joined(separator: ", ")) "
          + "for session '\(sessionID)': transcript is empty (\(verdict.summary))")
      return true
    }

    var nextInput = transcriptPath
    if stages.contains(.cleanup) {
      guard
        let cleanPath = await runPathStage(
          .cleanup, arguments: [transcriptPath, "--json"], sessionID: sessionID, context: context,
          issues: &issues)
      else { return true }  // transcribe already succeeded; chain stops here
      nextInput = cleanPath
    }

    if stages.contains(.summarize) {
      // `--select-preset`, not `--all-presets`: a conversation has one type,
      // and summarizing a user-research call as a workshop as well cost a
      // second LLM call to produce a note that then overwrote the right one
      // (two presets writing to `out = "{notes}"` collide on one path, and
      // config order decided which survived). summarize classifies the
      // transcript against each preset's `when` description and runs the one
      // that matches; `--all-presets` survives for reruns by hand.
      //
      // Summarize still has no single output path to thread — exit 0 is the
      // success signal, exactly as before the envelope. The envelope's
      // per-preset `outputs` feed the log: what was written on success here,
      // and — via `spawn`'s error-envelope decode — partial success ("wrote
      // 2/3 presets") on failure.
      if let outcome = await spawn(
        .summarize, arguments: [nextInput, "--select-preset", "--json"], sessionID: sessionID,
        context: context, issues: &issues)
      {
        notes = logSummarizeResults(
          stdout: outcome.stdout, sessionID: sessionID, context: context, issues: &issues)
      }
    }
    return true
  }

  /// Judges the just-written transcript against the emptiness thresholds, or
  /// `nil` when the document can't be read or parsed.
  ///
  /// An unreadable transcript is *not* treated as empty: the gate exists to
  /// stop the chain on a measurement, and a parse failure is not a
  /// measurement. It logs and lets the chain run exactly as it did before:
  /// running costs an LLM call, where wrongly skipping loses a real note.
  private func emptinessVerdict(
    transcriptPath: String, policy: TranscriptEmptinessPolicy, sessionID: String, context: String
  ) -> TranscriptEmptinessVerdict? {
    let frontmatter: TranscriptFrontmatter
    do {
      let markdown = try String(contentsOfFile: transcriptPath, encoding: .utf8)
      frontmatter = try TranscriptParser.parseFrontmatter(markdown)
    } catch {
      log(
        "\(context) on_end: could not read the transcript's frontmatter for "
          + "session '\(sessionID)' at '\(transcriptPath)': \(error); "
          + "running the remaining stages")
      return nil
    }
    return policy.verdict(frontmatter: frontmatter)
  }

  /// Spawns a path-producing stage in `--json` mode and returns its
  /// envelope's `output` path, or `nil` on failure. Exit 0 with anything but
  /// one decodable v1 envelope carrying an `output` is a failure too — a
  /// silent or polluted success the chain can't build on, a breaking-major
  /// envelope, or an `ok: false` under exit 0 is treated exactly like a
  /// crash, loudly. So is an `output` with no file behind it: the existence
  /// check kills a lie or stale path at this seam instead of letting it
  /// corrupt a later stage.
  private func runPathStage(
    _ stage: OnEndStage, arguments: [String], sessionID: String, context: String,
    issues: inout [PipelineIssue]
  ) async -> String? {
    guard
      let outcome = await spawn(
        stage, arguments: arguments, sessionID: sessionID, context: context, issues: &issues)
    else { return nil }
    let envelope: StageResultEnvelope
    switch StageResultEnvelope.decodeSuccessDocument(stdout: outcome.stdout, tool: stage.rawValue)
    {
    case .success(let decoded):
      envelope = decoded
    case .failure(let violation):
      log(
        "\(context) on_end: \(stage.rawValue) exited 0 but failed for "
          + "session '\(sessionID)': \(violation.message)")
      issues.append(PipelineIssue(stage: stage.rawValue, kind: .failed, message: violation.message))
      return nil
    }
    guard let path = envelope.output else {
      log(
        "\(context) on_end: \(stage.rawValue) exited 0 but failed for "
          + "session '\(sessionID)': result envelope carries no output path; "
          + Self.stdoutNote(outcome.stdout))
      issues.append(
        PipelineIssue(
          stage: stage.rawValue, kind: .failed,
          message: "result envelope carries no output path"))
      return nil
    }
    guard FileManager.default.fileExists(atPath: path) else {
      log(
        "\(context) on_end: \(stage.rawValue) exited 0 but failed for "
          + "session '\(sessionID)': envelope output path '\(path)' does not exist")
      issues.append(
        PipelineIssue(
          stage: stage.rawValue, kind: .failed,
          message: "envelope output path '\(path)' does not exist"))
      return nil
    }
    return path
  }

  /// Logs summarize's per-preset results from its success envelope's
  /// `outputs` — e.g. `summarize wrote 3/3 presets`. Exit 0 already carried
  /// the success signal, so an undecodable envelope here is logged loudly as
  /// a contract violation but changes nothing else.
  ///
  /// - Returns: the paths the envelope says were written, or `nil` when the
  ///   envelope is unusable and the written paths are unknown.
  private func logSummarizeResults(
    stdout: String, sessionID: String, context: String, issues: inout [PipelineIssue]
  ) -> [String]? {
    switch StageResultEnvelope.decodeSuccessDocument(
      stdout: stdout, tool: OnEndStage.summarize.rawValue)
    {
    case .success(let envelope):
      guard let presets = envelope.presetOutputs, !presets.isEmpty else { return [] }
      log(
        "\(context) on_end: \(Self.presetSummary(presets)) for session '\(sessionID)'")
      return presets.filter(\.ok).compactMap(\.path)
    case .failure(let violation):
      log(
        "\(context) on_end: summarize exited 0 but its result envelope is unusable for "
          + "session '\(sessionID)': \(violation.message)")
      issues.append(
        PipelineIssue(
          stage: OnEndStage.summarize.rawValue, kind: .failed, message: violation.message))
      return nil
    }
  }

  /// The per-preset summary line's core, e.g.
  /// `summarize wrote 2/3 presets (failed: actions)`.
  private static func presetSummary(_ presets: [StageResultEnvelope.PresetResult]) -> String {
    let written = presets.filter(\.ok).count
    let failed = presets.filter { !$0.ok }.map(\.preset)
    let failures = failed.isEmpty ? "" : " (failed: \(failed.joined(separator: ", ")))"
    return "summarize wrote \(written)/\(presets.count) presets\(failures)"
  }

  /// Spawns one stage with the issue-#21 logging contract: the full argv is
  /// logged *before* the run (so the log shows what was spawned even for a
  /// child that dies instantly), and a non-zero exit logs the exit code plus
  /// bounded stderr. Returns `nil` on non-zero exit.
  private func spawn(
    _ stage: OnEndStage, arguments: [String], sessionID: String, context: String,
    issues: inout [PipelineIssue]
  ) async -> SpawnOutcome? {
    log(
      "\(context) on_end: spawning \(stage.rawValue) \(arguments.joined(separator: " ")) "
        + "for session '\(sessionID)'")
    let outcome = await runProcess(stage.rawValue, arguments)
    guard outcome.exitCode == 0 else {
      // The exit-code taxonomy's class label (`EarsCLISupport.ExitClass`,
      // issue #61) rides in the failure line — e.g. `(exit 5,
      // retryable-upstream)` — so a future retry policy is a function of the
      // code with no re-plumbing, and a code outside the taxonomy (a crash
      // signal, a stray bare 1) is honestly `unclassified`. When the last
      // stderr line decodes as the `--json` error envelope, its
      // `exit_class`/`message` ride along too — augmenting, never replacing,
      // the bounded raw stderr (issue #21).
      let envelope = StageResultEnvelope.decodeErrorEnvelope(stderr: outcome.stderr)
      var line =
        "\(context) on_end: \(stage.rawValue) failed "
        + "(exit \(outcome.exitCode), \(ExitClass.label(forCode: outcome.exitCode))) for "
        + "session '\(sessionID)'"
      if let envelope {
        line +=
          "; envelope: \(envelope.exitClass ?? "unclassified") — "
          + (envelope.message ?? "no message")
      }
      line += "; \(Self.stderrNote(outcome.stderr))"
      log(line)
      issues.append(
        PipelineIssue(
          stage: stage.rawValue, kind: .failed,
          message: Self.failureMessage(
            envelope: envelope, stderr: outcome.stderr, exitCode: outcome.exitCode),
          exitClass: envelope?.exitClass ?? ExitClass.label(forCode: outcome.exitCode)))
      // A failed summarize's error envelope still carries per-preset results,
      // so partial success ("wrote 2/3 presets") is visible in the daemon log
      // instead of vanishing into a bare exit code.
      if stage == .summarize, let presets = envelope?.presetOutputs, !presets.isEmpty {
        log("\(context) on_end: \(Self.presetSummary(presets)) for session '\(sessionID)'")
      }
      return nil
    }
    log("\(context) on_end: \(stage.rawValue) succeeded for session '\(sessionID)'")
    // Exit 0 is not the same as "nothing to say". A stage that degraded — the
    // notes file it was configured to fold in wasn't there, a cleanup chunk
    // fell back — says so on stderr and still exits 0, and until now that
    // line was discarded with the rest of the successful child's capture.
    let diagnostics = Self.plainDiagnostics(outcome.stderr)
    if !diagnostics.isEmpty {
      log(
        "\(context) on_end: \(stage.rawValue) reported for session '\(sessionID)': "
          + diagnostics)
    }
    issues.append(
      contentsOf: Self.warnings(outcome.stderr).map {
        PipelineIssue(stage: stage.rawValue, kind: .warning, message: $0)
      })
    return outcome
  }

  /// The one-line reason a failed stage gives: its error envelope's message,
  /// else its last plain stderr line, each without the `error: ` prefix.
  static func failureMessage(
    envelope: StageResultEnvelope?, stderr: String, exitCode: Int32
  ) -> String {
    let message =
      envelope?.message
      ?? plainDiagnostics(stderr).split(separator: "\n").last.map(String.init)
    guard let message, !message.isEmpty else { return "exited \(exitCode) with no error message" }
    return message.hasPrefix("error: ") ? String(message.dropFirst("error: ".count)) : message
  }

  /// A successful stage's `warning:` lines, without the prefix.
  static func warnings(_ stderr: String) -> [String] {
    plainDiagnostics(stderr)
      .split(separator: "\n")
      .filter { $0.hasPrefix("warning: ") }
      .map { String($0.dropFirst("warning: ".count)) }
  }

  /// The largest slice of a child's captured output (stderr or stdout) the
  /// daemon log carries, in bytes: enough for a real Swift error and some
  /// context, bounded so a runaway child can't flood the log (issue #21's
  /// "captured stderr (bounded)").
  static let maxCaptureLogBytes = 4096

  /// A one-line, log-safe rendering of a child's stderr for a failure notice:
  /// `"no stderr captured"` when empty, else `stderr: <text>` with the text
  /// trimmed and bounded to ``maxCaptureLogBytes`` (keeping the *tail* — the
  /// `error: …` line a failing stage writes last).
  static func stderrNote(_ stderr: String) -> String {
    let bounded = boundedCapture(stderr)
    return bounded.isEmpty ? "no stderr captured" : "stderr: \(bounded)"
  }

  /// A *successful* stage's plain-text stderr: every line that is not one of
  /// its structured JSON-Lines log records, newline-joined and bounded like a
  /// failure capture.
  ///
  /// Stages write two interleaved things to stderr — their JSON-Lines log
  /// (which the daemon's own log already carries by every other route) and
  /// plain diagnostics meant for a human: `warning: preset 'meeting': no
  /// notes file at …`, `cleanup: rejected a cleanup candidate …`. Only the
  /// second is worth re-logging on success, and only the second is what exit
  /// 0 was hiding. The 2026-08-12 `meet 96DC3F7J7x0B` run warned that the
  /// jotted note it was configured to fold in did not exist at the templated
  /// path, summarized the call without it, and overwrote that path anyway;
  /// the daemon log recorded `summarize wrote 1/1 presets` and nothing else,
  /// so the one line that identified the fault survived only in the child's
  /// discarded stderr.
  static func plainDiagnostics(_ captured: String) -> String {
    let lines =
      captured
      .split(separator: "\n", omittingEmptySubsequences: true)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      // A JSON-Lines record is the structured log; anything else is prose for
      // the operator. Prefix-matching `{` is enough — the stages emit one
      // compact record per line, never a pretty-printed one.
      .filter { !$0.isEmpty && !$0.hasPrefix("{") }
    return boundedCapture(lines.joined(separator: "\n"))
  }

  /// ``stderrNote(_:)``'s stdout twin, for contract-violation notices:
  /// `"no stdout captured"` when empty, else `stdout: <text>`, bounded the
  /// same way.
  static func stdoutNote(_ stdout: String) -> String {
    let bounded = boundedCapture(stdout)
    return bounded.isEmpty ? "no stdout captured" : "stdout: \(bounded)"
  }

  /// Trims and length-bounds a captured child output for logging, keeping the
  /// tail and marking any elision. Exposed (not private) so the
  /// failure-logging contract is unit-testable without spawning a real child.
  static func boundedCapture(_ captured: String) -> String {
    let trimmed = captured.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.utf8.count > maxCaptureLogBytes else { return trimmed }
    let tail = String(decoding: trimmed.utf8.suffix(maxCaptureLogBytes), as: UTF8.self)
    return "…(truncated) " + tail
  }

  /// The production ``ProcessRunner``: spawns `name` (PATH-resolved via
  /// `/usr/bin/env`) with `arguments`, captures its stderr and stdout, waits
  /// for exit, and returns all three.
  ///
  /// Both pipes are drained *as the child writes them* (via each read
  /// handle's readability callback), not read once after exit: a child that
  /// writes more than one pipe buffer (~64 KB) would otherwise block on the
  /// write — never reaching exit — while this waited for an exit that never
  /// comes.
  public static let realProcessRunner: ProcessRunner = { name, arguments in
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [name] + arguments
    let stderrPipe = Pipe()
    process.standardError = stderrPipe
    let stdoutPipe = Pipe()
    process.standardOutput = stdoutPipe

    let stderrCollector = PipeCollector()
    let stdoutCollector = PipeCollector()
    // The callbacks receive the read handle as their parameter, so no
    // non-`Sendable` `FileHandle` is captured across the concurrency boundary.
    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
      stderrCollector.ingest(handle.availableData) { handle.readabilityHandler = nil }
    }
    stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
      stdoutCollector.ingest(handle.availableData) { handle.readabilityHandler = nil }
    }

    let exitCode: Int32 = await withCheckedContinuation { continuation in
      // Set the handler *before* `run()` so a child that exits before the
      // handler is installed can't leave the continuation hanging.
      process.terminationHandler = { finished in
        continuation.resume(returning: finished.terminationStatus)
      }
      do {
        try process.run()
      } catch {
        process.terminationHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrCollector.finish()
        stdoutCollector.finish()
        continuation.resume(returning: -1)
      }
    }
    let stderr = await stderrCollector.value()
    let stdout = await stdoutCollector.value()
    return SpawnOutcome(exitCode: exitCode, stderr: stderr, stdout: stdout)
  }
}

/// Accumulates one pipe of a child process's output, delivered piecemeal by a
/// `FileHandle.readabilityHandler`, and hands the full text to an `async`
/// awaiter once the stream reaches EOF.
///
/// A dedicated type (rather than inline closures) so the continuation/EOF
/// handshake — which must resume its awaiter exactly once whether EOF arrives
/// before or after ``value()`` is called — lives in one auditable place.
/// `Sendable` without `@unchecked`: its only stored state is a
/// `Synchronization.Mutex`, and every field it guards is itself `Sendable`.
private final class PipeCollector: Sendable {
  private struct State {
    var data = Data()
    var finished = false
    var waiter: CheckedContinuation<String, Never>? = nil
  }
  private let state = Mutex(State())

  /// Appends one readability chunk. Foundation delivers an empty chunk at EOF:
  /// that runs `onEOF` (to detach the handler and stop further callbacks) and
  /// releases any awaiter.
  func ingest(_ chunk: Data, onEOF: () -> Void) {
    guard chunk.isEmpty else {
      state.withLock { $0.data.append(chunk) }
      return
    }
    onEOF()
    finish()
  }

  /// Marks the stream complete and resumes a waiting ``value()`` if one is
  /// already parked. Idempotent — a second call (e.g. the spawn-failure path)
  /// is a no-op.
  func finish() {
    let resumption = state.withLock { s -> (CheckedContinuation<String, Never>, String)? in
      guard !s.finished else { return nil }
      s.finished = true
      guard let waiter = s.waiter else { return nil }
      s.waiter = nil
      return (waiter, String(decoding: s.data, as: UTF8.self))
    }
    if let resumption {
      resumption.0.resume(returning: resumption.1)
    }
  }

  /// The full captured text, awaiting EOF if it has not arrived yet.
  func value() async -> String {
    await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
      let immediate = state.withLock { s -> String? in
        guard s.finished else {
          s.waiter = continuation
          return nil
        }
        return String(decoding: s.data, as: UTF8.self)
      }
      if let immediate { continuation.resume(returning: immediate) }
    }
  }
}

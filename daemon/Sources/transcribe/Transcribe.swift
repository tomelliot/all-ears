import ArgumentParser
import EarsCLISupport
import Foundation

/// Reads captured audio chunks and the VAD index for a source/time-range, runs the
/// ASR model, and writes a transcript to the output location. See
/// `docs/architecture.md`.
///
/// Every invocation runs through `EarsCLI.run(tool:version:arguments:work:)`
/// -- the day-one config/logging contract every tool satisfies
/// (`--print-config`/`--config-path`, and for a normal run, the `LogSink`
/// bootstrap plus a `run.start` JSON Lines record). The real work is passed as
/// that call's `work` closure, so the final `run.summary` is logged *after* it
/// completes and reflects its true outcome -- a failed run logs a failure
/// status and the error message, never an optimistic `status=ok` (issue #25).
/// A normal invocation (neither flag set) runs
/// ``TranscribeRuntime``: it resolves `--last`/`--source`/`--out` into a
/// requested range and sources, reads each source's real captured audio,
/// runs the ASR backend, and writes the transcript. `--follow <source>`
/// instead runs ``FollowRuntime``/``TranscribeFollowPipeline``: attach to a
/// live source and stream finalised segments (stdout + transcript file +
/// the daemon's live feed) until signalled. See `docs/specs/transcribe.md`.
@main
struct Transcribe: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "transcribe",
    // The frozen plain-mode stdout contract (issue #62) and the shared
    // exit-code taxonomy (issue #61), documented where an operator will
    // actually look for them.
    discussion: PlainModeContract.helpEpilogue + "\n\n" + ExitClass.helpEpilogue
  )

  @Option(name: .customLong("config"), help: "Path to a TOML config file.")
  var config: String?

  @Flag(
    name: .customLong("print-config"), help: "Print the resolved, merged config as TOML and exit.")
  var printConfig = false

  @Flag(
    name: .customLong("config-path"),
    help: "Print which config file would be loaded (or that none was found) and exit."
  )
  var configPath = false

  @Option(
    name: .customLong("log-level"),
    help: "Override the effective log level (debug|info|notice|error).")
  var logLevel: String?

  @Option(name: .customLong("log-file"), help: "Override the JSON Lines log file path.")
  var logFile: String?

  @Flag(
    name: [.customShort("v"), .customLong("verbose")],
    help:
      "Verbose diagnostics (shorthand for --log-level debug). Diagnostics go to stderr only; stdout keeps the plain-mode contract."
  )
  var verbose = false

  @Option(
    name: .customLong("set"),
    help:
      "Override any config setting: --set path.to.key=value (repeatable). Values are typed (true/false, ints, floats); use --set-string to force a string."
  )
  var set: [String] = []

  @Option(
    name: .customLong("set-string"),
    help:
      "Like --set but the value is always a string: --set-string path.to.key=value (repeatable)."
  )
  var setString: [String] = []

  @Option(name: .customLong("last"), help: "Range ending now (e.g. 30m, 2h).")
  var last: String?

  @Option(name: .customLong("from"), help: "Explicit range start (ISO-8601 UTC).")
  var from: String?

  @Option(name: .customLong("to"), help: "Explicit range end (ISO-8601 UTC).")
  var to: String?

  @Option(
    name: .customLong("session"),
    help: "Union a session's transcription intervals into one transcript (session id).")
  var session: String?

  @Flag(
    name: .customLong("rereconcile"),
    help:
      "Re-derive the session's speaker map from its roster with the current reconciler, ignoring the stored [[speaker]] map (requires --session)."
  )
  var rereconcile = false

  @Option(name: .customLong("source"), help: "Source(s) to transcribe; repeatable.")
  var sources: [String] = []

  @Option(
    name: .customLong("file"),
    help:
      "Transcribe a standalone audio file (e.g. a .m4a) directly, bypassing the capture store; repeatable, one transcript written per file, next to its input (--out overrides, single file only)."
  )
  var files: [String] = []

  @Option(name: .customLong("out"), help: "Override the output transcript path.")
  var out: String?

  @Option(
    name: .customLong("follow"),
    help: "Attach to a live source by id and stream finalised segments until signalled.")
  var follow: String?

  // One flag, two mutually exclusive modes (issue #63's recorded decision):
  // under `--follow` it streams JSON *segment lines*; in batch mode it emits
  // the one JSON *result envelope* (allears.transcribe/v1). The modes can't
  // combine, so the flag is unambiguous at every call site.
  @Flag(
    name: .customLong("json"),
    help:
      "Follow mode: emit JSON segment lines to stdout instead of plain text. Batch mode: emit a versioned JSON result envelope (allears.transcribe/v1) as the only stdout document on success; on failure stdout stays empty and the last stderr line is the error envelope."
  )
  var json = false

  func run() async throws {
    let arguments = EarsCLI.Arguments(
      config: config,
      printConfig: printConfig,
      configPath: configPath,
      // `--verbose` is shorthand for `--log-level debug`; an explicit
      // `--log-level` wins so the two spellings never fight. It only widens
      // what reaches stderr and the log file — stdout is untouched, per the
      // plain-mode contract (issue #62).
      logLevel: logLevel ?? (verbose ? "debug" : nil),
      logFile: logFile,
      set: set,
      setString: setString
    )

    // Pure argument-combination validation runs first, as usage errors: they
    // must reject an invalid invocation without producing a `run.summary` for
    // a run that never started, so they stay ArgumentParser `ValidationError`s
    // (usage exit) rather than a logged failure outcome.
    try validateArgumentCombinations()

    // Snapshot the flags into locals the `@Sendable` work closure captures.
    let files = self.files
    let follow = self.follow
    let json = self.json
    let last = self.last
    let from = self.from
    let to = self.to
    let session = self.session
    let sources = self.sources
    let out = self.out
    let rereconcile = self.rereconcile

    // The real run happens inside `work`, between `run.start` and
    // `run.summary`; the summary now reflects the outcome we return here,
    // never a `status=ok` logged before the work could fail (issue #25). The
    // `--print-config`/`--config-path` fast paths return before `work` runs.
    // No `transcribe` run writes into `output_root` any more — raw
    // transcripts are intermediates in the data store, and only `cleanup`
    // publishes — so `run.start` omits the field rather than advertising a
    // directory the run never touches.
    let diagnostics = RunDiagnostics()
    let exitCode = await EarsCLI.run(
      tool: "transcribe", version: "0.1.0", arguments: arguments,
      usesOutputRoot: false
    ) { bootstrap in
      if !files.isEmpty {
        return await TranscribeRuntime.runFiles(
          arguments: arguments,
          inputs: TranscribeFilePipeline.Inputs(files: files, out: out),
          diagnostics: diagnostics)
      }
      if let follow {
        return await FollowRuntime.run(
          arguments: arguments,
          inputs: TranscribeFollowPipeline.Inputs(source: follow, json: json, out: out),
          diagnostics: diagnostics)
      }
      // Stage spans go to the same sink as run.start/run.summary, so per-stage
      // timing correlates with the run it belongs to (docs/logging.md).
      return await TranscribeRuntime.run(
        arguments: arguments,
        inputs: TranscribePipeline.Inputs(
          last: last, from: from, to: to, session: session, sourceIDs: sources,
          out: out, rereconcile: rereconcile),
        diagnostics: diagnostics,
        spans: bootstrap.stageSpans(tool: "transcribe"),
        emitJSONEnvelope: json)
    }
    // The batch `--json` failure contract (issue #63): stdout stays
    // byte-empty (the runtime never emitted a success envelope) and the
    // *last line of stderr* is the error envelope — written here, after
    // `EarsCLI.run` has already echoed the failed run's `run.summary` to
    // stderr, so nothing can land after it. Only the batch path: under
    // `--follow`, `--json` means segment lines, and `--file` rejects the
    // flag outright.
    if exitCode != 0, json, follow == nil, files.isEmpty {
      let envelope = TranscribeResultEnvelope.failure(
        exitClass: ExitClass.label(forCode: exitCode),
        message: diagnostics.lastError ?? "error: transcribe failed (exit \(exitCode))")
      if let line = StageEnvelopeJSON.encodeLine(envelope) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
      }
    }
    guard exitCode == 0 else { throw ExitCode(exitCode) }
  }

  /// Extensions `--file` users plausibly pass. Matched by extension rather than
  /// "has a dot", because source ids such as `app:us.zoom.xos` contain dots.
  private static let audioFileExtensions: Set<String> = [
    "m4a", "mp3", "wav", "aac", "flac", "ogg", "opus", "caf", "aif", "aiff", "mp4", "mov", "webm",
  ]

  /// Whether a `--source` value is a file path rather than a source id: an
  /// existing regular file, or a name ending in an audio extension.
  static func looksLikeAudioFile(_ value: String) -> Bool {
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: value, isDirectory: &isDirectory),
      !isDirectory.boolValue
    {
      return true
    }
    let pathExtension = (value as NSString).pathExtension.lowercased()
    return audioFileExtensions.contains(pathExtension)
  }

  /// Rejects mutually exclusive flag combinations before any run. Mirrors the
  /// per-mode guards the dispatch in ``run()`` relies on having already passed.
  private func validateArgumentCombinations() throws {
    // The speaker map is a session artifact, so re-reconciling one is
    // meaningless without a session to read the roster from — checked first
    // so `--file --rereconcile` and `--follow --rereconcile` get this
    // precise error rather than the generic combination one.
    if rereconcile, session == nil {
      throw ValidationError("--rereconcile requires --session")
    }
    // `--source` takes a capture-store source id, but a file path passed to it
    // otherwise falls through to range resolution and fails with an unrelated
    // "no range specified". Checked before the combination guards so the hint
    // wins over a generic mixing error.
    if let path = sources.first(where: Self.looksLikeAudioFile) {
      throw ValidationError(
        "--source takes a source id, not a file: '\(path)'; to transcribe a file use --file <path>")
    }
    if !files.isEmpty {
      // `--file` is a standalone-file batch: every range/session selector
      // and the live-`--follow` attach make no sense against a file
      // with no index and no wall-clock time, so mixing them is a precise
      // error rather than a silent ignore (matching `--follow`/`--session`).
      guard follow == nil, last == nil, from == nil, to == nil, session == nil,
        sources.isEmpty, !json
      else {
        throw ValidationError(
          "--file cannot be combined with "
            + "--follow/--last/--from/--to/--session/--source/--json")
      }
      return
    }
    if follow != nil {
      // Follow is attach-and-tail; batch is resolve-a-range-and-exit. The
      // flags that shape a batch range make no sense here, so mixing them
      // is a precise error rather than a silent ignore.
      guard last == nil, from == nil, to == nil, session == nil, sources.isEmpty
      else {
        throw ValidationError(
          "--follow cannot be combined with --last/--from/--to/--session/--source")
      }
      return
    }
    // Batch `--json` (the result envelope, issue #63) is valid from here on:
    // the `--file` and `--follow` paths above have already returned, so no
    // rejection — the flag's two meanings can never collide in one run.
    if session != nil {
      // A session names its own range and sources; mixing selectors is a
      // precise error rather than a silent ignore.
      guard last == nil, from == nil, to == nil, sources.isEmpty else {
        throw ValidationError(
          "--session cannot be combined with --last/--from/--to/--source")
      }
    }
  }
}

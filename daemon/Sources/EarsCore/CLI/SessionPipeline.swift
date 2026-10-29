/// Pure derivation of a session's pipeline state — capture → transcribe →
/// cleanup → summarize → note — from its `Session` record plus what a disk
/// scan found (``SessionArtifacts``). The scan itself is I/O and lives in the
/// `ears` executable; everything here is a deterministic function of its
/// inputs, per `docs/engineering-practices.md`'s tier-0 rule.
public enum SessionPipeline {
  /// How long after `ended` an absent artifact still reads as "running"
  /// rather than "missing": the on-end chain (transcribe, then two LLM
  /// stages) legitimately takes minutes, and a pipeline view that calls a
  /// stage failed while it is mid-flight teaches users to distrust it.
  public static let recentGraceSeconds: Double = 15 * 60

  /// The five stage rows of `ears session show`, in pipeline order.
  ///
  /// `emptiness` is the daemon's own gate (`[earsd.sessions] min_words` /
  /// `min_speech_seconds`), so a chain the daemon stopped after transcribe
  /// renders as skipped rather than as three absent artifacts.
  public static func stages(
    session: Session, artifacts: SessionArtifacts, now: Instant,
    emptiness: TranscriptEmptinessPolicy = .defaults
  ) -> [PipelineStage] {
    let live = session.state != .ended
    if live {
      return [captureStage(session: session, artifacts: artifacts, live: true)]
        + ["transcribe", "cleanup", "summarize", "note"].map {
          PipelineStage(name: $0, state: .waiting, detail: "waits for session end")
        }
    }

    let recent = isRecent(session: session, now: now)
    let transcribeDone = transcribeDone(session: session, artifacts: artifacts)
    // The reason the later stages are absent, when the daemon's gate is what
    // made them absent. Only a transcript that actually parsed can say so:
    // no measurements, no claim.
    let skipReason = skipReason(artifacts: artifacts, emptiness: emptiness)

    var stages = [captureStage(session: session, artifacts: artifacts, live: false)]

    if transcribeDone {
      stages.append(
        PipelineStage(name: "transcribe", state: .done, detail: transcribeDetail(artifacts)))
    } else if let failure = failure(of: "transcribe", in: session) {
      stages.append(
        PipelineStage(name: "transcribe", state: .failed, detail: failedDetail(failure)))
    } else {
      stages.append(
        recent
          ? PipelineStage(name: "transcribe", state: .running, detail: "running")
          : PipelineStage(name: "transcribe", state: .missing, detail: "no transcript on disk"))
    }

    stages.append(
      laterStage(
        name: "cleanup",
        done: artifacts.cleanupExists,
        doneDetail: artifacts.cleanupSegments.map { "\(HumanUnits.grouped($0)) segments cleaned" }
          ?? "published",
        previousDone: transcribeDone,
        missingDetail: "not published",
        failure: failure(of: "cleanup", in: session),
        recent: recent,
        skipReason: skipReason))

    let summarizeDone = artifacts.summaryCount > 0 || artifacts.noteLink != nil
    stages.append(
      laterStage(
        name: "summarize",
        done: summarizeDone,
        doneDetail: artifacts.summaryCount > 0
          ? "\(artifacts.summaryCount) preset\(artifacts.summaryCount == 1 ? "" : "s")"
          : "note published",
        previousDone: artifacts.cleanupExists,
        missingDetail: "no summaries",
        failure: failure(of: "summarize", in: session),
        recent: recent,
        skipReason: skipReason))

    stages.append(
      laterStage(
        name: "note",
        done: artifacts.noteLink != nil,
        doneDetail: artifacts.noteLink.map(displayNoteLink) ?? "",
        previousDone: summarizeDone,
        missingDetail: "not published",
        recent: recent,
        skipReason: skipReason))

    return stages
  }

  /// The one-line outcome `ears sessions` and the status dashboard's recent
  /// tail show per session.
  public static func outcome(
    session: Session, artifacts: SessionArtifacts, now: Instant,
    emptiness: TranscriptEmptinessPolicy = .defaults
  ) -> PipelineOutcome {
    switch session.state {
    case .active:
      let elapsed = HumanUnits.duration(seconds: now.interval(since: session.started))
      return PipelineOutcome(glyph: "●", text: "recording (\(elapsed))")
    case .paused:
      let elapsed = HumanUnits.duration(seconds: now.interval(since: session.started))
      return PipelineOutcome(glyph: "◐", text: "paused (\(elapsed))")
    case .ended:
      break
    }

    let warningCount = warningCount(session)
    let warningsSuffix = ", \(warningCount) warning\(warningCount == 1 ? "" : "s")"
    if artifacts.noteLink != nil {
      guard warningCount == 0 else {
        return PipelineOutcome(glyph: "⚠", text: "published\(warningsSuffix)")
      }
      return PipelineOutcome(glyph: "✓", text: "published")
    }

    let recent = isRecent(session: session, now: now)
    let base: PipelineOutcome
    if let failure = session.pipelineIssues.first(where: { $0.kind == .failed }) {
      // A recorded failure is a fact, not a stage still in flight: name the
      // stage and its exit class, and leave the message to `ears session show`.
      let failed = "\(failure.stage) failed" + (failure.exitClass.map { " (\($0))" } ?? "")
      base = PipelineOutcome(
        glyph: "✗",
        text: transcribeDone(session: session, artifacts: artifacts)
          ? "transcribed, \(failed)" : failed)
    } else if transcribeDone(session: session, artifacts: artifacts) {
      // A gated session has a transcript and will never have a note; saying
      // "summarizing" of it would be a wait that never ends.
      if skipReason(artifacts: artifacts, emptiness: emptiness) != nil {
        base = PipelineOutcome(glyph: "–", text: "empty, not summarized")
      } else {
        base =
          recent
          ? PipelineOutcome(glyph: "·", text: "summarizing")
          : PipelineOutcome(glyph: "–", text: "transcribed, no note")
      }
    } else {
      base =
        recent
        ? PipelineOutcome(glyph: "·", text: "transcribing")
        : PipelineOutcome(glyph: "–", text: "no transcript")
    }
    guard warningCount == 0 else {
      return PipelineOutcome(
        glyph: base.glyph == "✗" ? "✗" : "⚠", text: base.text + warningsSuffix)
    }
    return base
  }

  /// Where `ears session retry` resumes: the first of transcribe, cleanup
  /// and summarize that did not finish, read off ``stages(session:artifacts:now:emptiness:)``.
  public static func retryStart(_ stages: [PipelineStage]) -> RetryStart {
    for name in ["transcribe", "cleanup", "summarize"] {
      guard let stage = stages.first(where: { $0.name == name }) else {
        return .live  // a live session's view stops at capture
      }
      switch stage.state {
      case .done: continue
      case .skipped: return .emptyTranscript
      case .waiting: return .live
      case .failed, .missing, .running: return .from(name)
      }
    }
    return .nothingToRetry
  }

  // MARK: - Stage helpers

  private static func isRecent(session: Session, now: Instant) -> Bool {
    guard let ended = session.ended else { return true }
    return now.interval(since: ended) < recentGraceSeconds
  }

  private static func transcribeDone(session: Session, artifacts: SessionArtifacts) -> Bool {
    session.transcriptCompleted != nil || artifacts.transcriptExists
  }

  /// Attribution warnings plus the `warning:` lines the on-end stages wrote.
  private static func warningCount(_ session: Session) -> Int {
    session.warnings.count + session.pipelineIssues.filter { $0.kind == .warning }.count
  }

  private static func failure(of stage: String, in session: Session) -> PipelineIssue? {
    session.pipelineIssues.first { $0.stage == stage && $0.kind == .failed }
  }

  /// `failed (retryable-upstream): LLM backend call timed out`.
  private static func failedDetail(_ failure: PipelineIssue) -> String {
    "failed" + (failure.exitClass.map { " (\($0))" } ?? "") + ": \(failure.message)"
  }

  private static func captureStage(
    session: Session, artifacts: SessionArtifacts, live: Bool
  ) -> PipelineStage {
    guard !artifacts.captureBytesBySource.isEmpty else {
      if live {
        return PipelineStage(name: "capture", state: .running, detail: "recording")
      }
      if transcribeDone(session: session, artifacts: artifacts) {
        return PipelineStage(
          name: "capture", state: .done, detail: "audio evicted (transcript retained)")
      }
      return PipelineStage(name: "capture", state: .missing, detail: "no audio on disk")
    }
    return PipelineStage(
      name: "capture",
      state: live ? .running : .done,
      detail: captureDetail(session: session, artifacts: artifacts))
  }

  private static func captureDetail(session: Session, artifacts: SessionArtifacts) -> String {
    var micBytes = 0
    var remoteBytes = 0
    for (source, bytes) in artifacts.captureBytesBySource {
      if source.sourceClass == .mic {
        micBytes += bytes
      } else {
        remoteBytes += bytes
      }
    }
    var parts: [String] = []
    if micBytes > 0 { parts.append("\(HumanUnits.bytes(micBytes)) mic") }
    if remoteBytes > 0 { parts.append("\(HumanUnits.bytes(remoteBytes)) remote") }
    var detail = parts.joined(separator: ", ")

    // The speech-evidence parenthetical, only where the flight recorder
    // actually reported: a session with no attribution log gets no claim.
    let tracks = browserTracks(session: session, artifacts: artifacts)
    if artifacts.hasAttributionLog, !tracks.isEmpty {
      let carried = tracks.filter { artifacts.speechCaptures.contains(captureHandle($0)) }.count
      detail += " (\(carried) of \(tracks.count) tracks carried speech)"
    }
    return detail
  }

  /// Every browser-class source this session involved — the union of what
  /// the session record names and what actually landed on disk, so a track
  /// admitted after the record was last written still counts.
  private static func browserTracks(
    session: Session, artifacts: SessionArtifacts
  ) -> [SourceID] {
    var seen = Set<SourceID>()
    var tracks: [SourceID] = []
    for source in session.sources + Array(artifacts.captureBytesBySource.keys)
    where source.sourceClass == .browser && seen.insert(source).inserted {
      tracks.append(source)
    }
    return tracks.sorted { $0.rawValue < $1.rawValue }
  }

  /// The capture handle the attribution log names a browser source by — the
  /// id's last `:` component (`browser:meet:t1` → `t1`), per
  /// ``AttributionBindingHint/captureId``'s "suffix of the earsd source
  /// label" contract.
  static func captureHandle(_ source: SourceID) -> String {
    source.rawValue.split(separator: ":").last.map(String.init) ?? source.rawValue
  }

  private static func laterStage(
    name: String,
    done: Bool,
    doneDetail: String,
    previousDone: Bool,
    missingDetail: String,
    failure: PipelineIssue? = nil,
    recent: Bool,
    skipReason: String?
  ) -> PipelineStage {
    if done { return PipelineStage(name: name, state: .done, detail: doneDetail) }
    if let failure {
      return PipelineStage(name: name, state: .failed, detail: failedDetail(failure))
    }
    // A stage the daemon's emptiness gate stopped is never coming — not
    // running, not queued, not a fault. The reason outranks the grace window
    // for exactly that reason.
    if let skipReason {
      return PipelineStage(name: name, state: .skipped, detail: skipReason)
    }
    if previousDone {
      return recent
        ? PipelineStage(name: name, state: .running, detail: "running")
        : PipelineStage(name: name, state: .missing, detail: missingDetail)
    }
    return recent
      ? PipelineStage(name: name, state: .waiting, detail: "queued")
      : PipelineStage(name: name, state: .missing, detail: "not run")
  }

  /// `skipped (empty transcript)` when the transcript on disk falls under the
  /// daemon's thresholds, `nil` otherwise — including when the transcript did
  /// not parse, when either measurement is absent, and when the gate is
  /// disabled.
  private static func skipReason(
    artifacts: SessionArtifacts, emptiness: TranscriptEmptinessPolicy
  ) -> String? {
    guard emptiness.isEnabled,
      let words = artifacts.transcriptWords,
      let speech = artifacts.transcriptSpeechSeconds,
      emptiness.verdict(wordCount: words, speechSeconds: speech).isEmpty
    else { return nil }
    return "skipped (empty transcript)"
  }

  private static func transcribeDetail(_ artifacts: SessionArtifacts) -> String {
    guard let segments = artifacts.transcriptSegments else { return "completed" }
    guard let words = artifacts.transcriptWords else {
      return "\(HumanUnits.grouped(segments)) segments"
    }
    return "\(HumanUnits.grouped(segments)) segments, \(HumanUnits.grouped(words)) words"
  }

  /// `[[calls/2026-08-17 - Matt Silva]]` → `calls/2026-08-17 - Matt Silva`;
  /// a plain path passes through untouched.
  private static func displayNoteLink(_ link: String) -> String {
    guard link.hasPrefix("[["), link.hasSuffix("]]") else { return link }
    return String(link.dropFirst(2).dropLast(2))
  }
}

/// What a disk scan of one session's directory (and its downstream published
/// artifacts) found. Assembled by the `ears` executable's scanner; consumed
/// by ``SessionPipeline``'s pure derivation.
public struct SessionArtifacts: Sendable, Equatable {
  /// On-disk bytes per session-scoped source copy (`sessions/<id>/sources/`).
  public var captureBytesBySource: [SourceID: Int] = [:]
  /// Whether `attribution.jsonl` exists — the gate on any speech/silence
  /// claim (no log, no claim).
  public var hasAttributionLog = false
  /// Capture handles (`t1`) with at least one decoded speech onset — see
  /// ``AttributionSpeechEvidence/speechCaptures``.
  public var speechCaptures: Set<String> = []
  /// Whether `sessions/<id>/transcript.md` exists.
  public var transcriptExists = false
  /// Its absolute path, when it exists — carried for the `--json` view.
  public var transcriptPath: String?
  /// Turn count parsed from the transcript, when it parsed.
  public var transcriptSegments: Int?
  /// `word_count` from the transcript's frontmatter, when it parsed.
  public var transcriptWords: Int?
  /// `speech_seconds` from the transcript's frontmatter, when it parsed —
  /// the other half of the emptiness test the daemon gated the chain on.
  public var transcriptSpeechSeconds: Double?
  /// Where `[cleanup] output` resolves for this session's transcript —
  /// computed whether or not anything is there yet.
  public var cleanupPath: String?
  /// Whether ``cleanupPath`` exists on disk.
  public var cleanupExists = false
  /// Turn count parsed from the cleaned transcript, when it parsed.
  public var cleanupSegments: Int?
  /// `*.summary.md` siblings derived from the cleaned transcript.
  public var summaryCount = 0
  /// The `note:` frontmatter link stamped into the cleaned transcript by
  /// `summarize` — the published note, in wikilink or absolute-path form.
  public var noteLink: String?

  public init() {}
}

/// ``SessionPipeline/retryStart(_:)``'s answer.
public enum RetryStart: Sendable, Equatable {
  /// Rerun from this stage (`transcribe`, `cleanup` or `summarize`).
  case from(String)
  /// Every stage finished.
  case nothingToRetry
  /// The daemon's emptiness gate stopped the chain on purpose.
  case emptyTranscript
  /// The session has not ended, so its chain has not run.
  case live
}

/// One row of the `ears session show` pipeline view.
public struct PipelineStage: Sendable, Equatable {
  public var name: String
  public var state: PipelineStageState
  public var detail: String

  public init(name: String, state: PipelineStageState, detail: String) {
    self.name = name
    self.state = state
    self.detail = detail
  }
}

/// A stage's derived condition. `missing` is deliberately neutral wording:
/// from disk alone, "artifact absent long after the session ended" is
/// distinguishable from "still in flight" but not from "stage disabled", so
/// the view never claims failure outright.
///
/// `skipped` is the one absent-artifact case the view *can* explain: the
/// daemon stops the on-end chain after transcribe when the transcript reads
/// as empty (``TranscriptEmptinessPolicy``), and the stages behind that gate
/// were never meant to run. Rendering them as `missing` reads as a fault the
/// user should chase.
public enum PipelineStageState: String, Sendable, Equatable, Codable {
  case done
  case running
  case waiting
  case missing
  case skipped
  /// The daemon's last on-end chain recorded this stage as failed
  /// (``Session/pipelineIssues``).
  case failed
}

/// A one-line pipeline outcome: a status glyph and its text.
public struct PipelineOutcome: Sendable, Equatable {
  public var glyph: String
  public var text: String

  public init(glyph: String, text: String) {
    self.glyph = glyph
    self.text = text
  }
}

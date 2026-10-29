import Testing

@testable import EarsCore

@Suite("SessionPipeline")
struct SessionPipelineTests {
  /// 2026-08-17T15:01:00Z.
  private let started = Instant(secondsSinceEpoch: 1_786_978_860)
  private var ended: Instant { started.advanced(by: 31 * 60) }
  /// Well past the post-end grace window.
  private var muchLater: Instant { ended.advanced(by: 3_600) }
  /// Inside the post-end grace window.
  private var justAfter: Instant { ended.advanced(by: 60) }

  private func session(
    state: SessionState = .ended,
    sources: [String] = ["mic", "browser:meet:t1", "browser:meet:t2", "browser:meet:t3"],
    warnings: [String] = [],
    pipelineIssues: [PipelineIssue] = []
  ) -> Session {
    Session(
      id: "3db61b03-aaaa-bbbb-cccc-ddddeeeeffff",
      title: "Matt Silva",
      state: state,
      started: started,
      ended: state == .ended ? ended : nil,
      warnings: warnings,
      sources: sources.map { SourceID($0) },
      pipelineIssues: pipelineIssues)
  }

  private func fullArtifacts() -> SessionArtifacts {
    var artifacts = SessionArtifacts()
    artifacts.captureBytesBySource = [
      SourceID("mic"): 33_000_000,
      SourceID("browser:meet:t1"): 15_000_000,
      SourceID("browser:meet:t2"): 3_000_000,
      SourceID("browser:meet:t3"): 3_100_000,
    ]
    artifacts.hasAttributionLog = true
    artifacts.speechCaptures = ["t1"]
    artifacts.transcriptExists = true
    artifacts.transcriptSegments = 177
    artifacts.transcriptWords = 5_745
    artifacts.cleanupPath = "/out/2026/08/17/2026-08-17 - Matt Silva.md"
    artifacts.cleanupExists = true
    artifacts.cleanupSegments = 177
    artifacts.summaryCount = 3
    artifacts.noteLink = "[[calls/2026-08-17 - Matt Silva]]"
    return artifacts
  }

  // MARK: - stage derivation, fully-published session

  @Test("a fully published session derives five done stages")
  func fullyPublishedSessionIsAllDone() {
    let stages = SessionPipeline.stages(
      session: session(), artifacts: fullArtifacts(), now: muchLater)
    #expect(stages.map(\.name) == ["capture", "transcribe", "cleanup", "summarize", "note"])
    #expect(stages.allSatisfy { $0.state == .done })
    #expect(stages[0].detail == "33 MB mic, 21 MB remote (1 of 3 tracks carried speech)")
    #expect(stages[1].detail == "177 segments, 5,745 words")
    #expect(stages[2].detail == "177 segments cleaned")
    #expect(stages[3].detail == "3 presets")
    #expect(stages[4].detail == "calls/2026-08-17 - Matt Silva")
  }

  @Test("a mic-only session's capture detail names no remote tracks")
  func micOnlyCaptureDetail() {
    var artifacts = SessionArtifacts()
    artifacts.captureBytesBySource = [SourceID("mic"): 9_904_279]
    let stages = SessionPipeline.stages(
      session: session(sources: ["mic"]), artifacts: artifacts, now: justAfter)
    #expect(stages[0].state == .done)
    #expect(stages[0].detail == "9.9 MB mic")
  }

  // MARK: - absence: recent means running, old means missing

  @Test("an ended-recently session with no transcript renders transcribe as running, not failed")
  func recentAbsenceIsRunning() {
    var artifacts = SessionArtifacts()
    artifacts.captureBytesBySource = [SourceID("mic"): 1_000]
    let stages = SessionPipeline.stages(
      session: session(sources: ["mic"]), artifacts: artifacts, now: justAfter)
    #expect(stages[1].state == .running)
    #expect(stages[2].state == .waiting)
    #expect(stages[3].state == .waiting)
    #expect(stages[4].state == .waiting)
  }

  @Test("long after the end, the same absence reads as missing")
  func oldAbsenceIsMissing() {
    var artifacts = SessionArtifacts()
    artifacts.captureBytesBySource = [SourceID("mic"): 1_000]
    let stages = SessionPipeline.stages(
      session: session(sources: ["mic"]), artifacts: artifacts, now: muchLater)
    #expect(stages[1].state == .missing)
    #expect(stages[1].detail == "no transcript on disk")
    #expect(stages[2].state == .missing)
    #expect(stages[2].detail == "not run")
  }

  @Test("evicted audio with a completed transcript still renders capture as done")
  func evictedAudioIsNotAFailure() {
    var artifacts = fullArtifacts()
    artifacts.captureBytesBySource = [:]
    let stages = SessionPipeline.stages(
      session: session(), artifacts: artifacts, now: muchLater)
    #expect(stages[0].state == .done)
    #expect(stages[0].detail == "audio evicted (transcript retained)")
  }

  // MARK: - active sessions

  @Test("an active session marks capture as running and every later stage as waiting")
  func activeSessionWaitsForEnd() {
    var artifacts = SessionArtifacts()
    artifacts.captureBytesBySource = [SourceID("mic"): 9_904_279]
    let stages = SessionPipeline.stages(
      session: session(state: .active, sources: ["mic"]), artifacts: artifacts,
      now: started.advanced(by: 26 * 60))
    #expect(stages[0].state == .running)
    #expect(stages[0].detail == "9.9 MB mic")
    for stage in stages.dropFirst() {
      #expect(stage.state == .waiting)
      #expect(stage.detail == "waits for session end")
    }
  }

  // MARK: - one-line outcomes

  @Test("outcomes: recording, published, published-with-warnings, in-flight, and stalled")
  func outcomeLines() {
    let active = session(state: .active)
    #expect(
      SessionPipeline.outcome(
        session: active, artifacts: SessionArtifacts(), now: started.advanced(by: 26 * 60))
        == PipelineOutcome(glyph: "●", text: "recording (26m)"))

    #expect(
      SessionPipeline.outcome(session: session(), artifacts: fullArtifacts(), now: muchLater)
        == PipelineOutcome(glyph: "✓", text: "published"))

    var warned = fullArtifacts()
    #expect(
      SessionPipeline.outcome(
        session: session(warnings: ["w1", "w2"]), artifacts: warned, now: muchLater)
        == PipelineOutcome(glyph: "⚠", text: "published, 2 warnings"))

    warned.noteLink = nil
    warned.summaryCount = 0
    #expect(
      SessionPipeline.outcome(session: session(), artifacts: warned, now: justAfter)
        == PipelineOutcome(glyph: "·", text: "summarizing"))
    #expect(
      SessionPipeline.outcome(session: session(), artifacts: warned, now: muchLater)
        == PipelineOutcome(glyph: "–", text: "transcribed, no note"))

    #expect(
      SessionPipeline.outcome(session: session(), artifacts: SessionArtifacts(), now: justAfter)
        == PipelineOutcome(glyph: "·", text: "transcribing"))
    #expect(
      SessionPipeline.outcome(session: session(), artifacts: SessionArtifacts(), now: muchLater)
        == PipelineOutcome(glyph: "–", text: "no transcript"))
  }

  @Test("a paused session's outcome says paused")
  func pausedOutcome() {
    #expect(
      SessionPipeline.outcome(
        session: session(state: .paused), artifacts: SessionArtifacts(),
        now: started.advanced(by: 600))
        == PipelineOutcome(glyph: "◐", text: "paused (10m)"))
  }

  // MARK: - recorded pipeline issues

  @Test("a recorded failure names the stage and class in the outcome, and the reason in its row")
  func recordedFailure() {
    var artifacts = fullArtifacts()
    artifacts.noteLink = nil
    artifacts.summaryCount = 0
    let failed = session(
      warnings: ["w1"],
      pipelineIssues: [
        PipelineIssue(
          stage: "summarize", kind: .failed, message: "LLM backend call timed out",
          exitClass: "retryable-upstream")
      ])

    // A recorded failure is not in flight, so the grace window doesn't apply.
    #expect(
      SessionPipeline.outcome(session: failed, artifacts: artifacts, now: justAfter)
        == PipelineOutcome(
          glyph: "✗", text: "transcribed, summarize failed (retryable-upstream), 1 warning"))
    let stages = SessionPipeline.stages(session: failed, artifacts: artifacts, now: muchLater)
    #expect(
      stages[3]
        == PipelineStage(
          name: "summarize", state: .failed,
          detail: "failed (retryable-upstream): LLM backend call timed out"))
    #expect(stages[4] == PipelineStage(name: "note", state: .missing, detail: "not run"))
  }

  @Test("stage warnings count toward the outcome's warnings")
  func stageWarningsCount() {
    let warned = session(pipelineIssues: [
      PipelineIssue(stage: "summarize", kind: .warning, message: "no notes file")
    ])
    #expect(
      SessionPipeline.outcome(session: warned, artifacts: fullArtifacts(), now: muchLater)
        == PipelineOutcome(glyph: "⚠", text: "published, 1 warning"))
  }

  // MARK: - the empty-transcript gate

  /// The 2026-08-20 605-second session as a disk scan finds it: a transcript
  /// on disk, nothing downstream of it, and the measurements that explain why.
  private func emptyTranscriptArtifacts() -> SessionArtifacts {
    var artifacts = SessionArtifacts()
    artifacts.captureBytesBySource = [SourceID("mic"): 4_100_000]
    artifacts.transcriptExists = true
    artifacts.transcriptSegments = 1
    artifacts.transcriptWords = 1
    artifacts.transcriptSpeechSeconds = 0.556
    return artifacts
  }

  @Test("an empty transcript renders the later stages as skipped, not missing")
  func emptyTranscriptRendersSkipped() {
    let stages = SessionPipeline.stages(
      session: session(), artifacts: emptyTranscriptArtifacts(), now: muchLater)
    #expect(stages[1].state == .done)
    for stage in stages[2...] {
      #expect(stage.state == .skipped)
      #expect(stage.detail == "skipped (empty transcript)")
    }
  }

  @Test("skipped outranks the grace window: a just-ended empty session is not 'running'")
  func skippedOutranksRecency() {
    let stages = SessionPipeline.stages(
      session: session(), artifacts: emptyTranscriptArtifacts(), now: justAfter)
    #expect(stages.filter { $0.state == .skipped }.map(\.name) == ["cleanup", "summarize", "note"])
  }

  @Test("with the gate disabled the same session reads as it did before")
  func disabledGateRendersMissing() {
    let stages = SessionPipeline.stages(
      session: session(), artifacts: emptyTranscriptArtifacts(), now: muchLater,
      emptiness: TranscriptEmptinessPolicy(minWords: 0, minSpeechSeconds: 0))
    #expect(!stages.contains { $0.state == .skipped })
    #expect(stages[2].state == .missing)
  }

  @Test("a transcript that did not parse claims nothing — no measurements, no skip")
  func unparsedTranscriptIsNotSkipped() {
    var artifacts = emptyTranscriptArtifacts()
    artifacts.transcriptWords = nil
    artifacts.transcriptSpeechSeconds = nil
    let stages = SessionPipeline.stages(
      session: session(), artifacts: artifacts, now: muchLater)
    #expect(!stages.contains { $0.state == .skipped })
  }

  @Test("a published note outranks the gate — what ran, ran")
  func publishedStagesStayDone() {
    var artifacts = fullArtifacts()
    artifacts.transcriptWords = 1
    artifacts.transcriptSpeechSeconds = 0.556
    let stages = SessionPipeline.stages(
      session: session(), artifacts: artifacts, now: muchLater)
    #expect(stages.allSatisfy { $0.state == .done })
  }

  @Test("the sessions list calls an empty session empty, not a stalled pipeline")
  func emptySessionOutcome() {
    let outcome = SessionPipeline.outcome(
      session: session(), artifacts: emptyTranscriptArtifacts(), now: justAfter)
    // Inside the grace window it would otherwise claim "summarizing" — a wait
    // that never ends, since nothing downstream was ever going to run.
    #expect(outcome.text == "empty, not summarized")
    #expect(outcome.glyph == "–")
  }

  // MARK: - retry start

  @Test("retry resumes at the failed cleanup, not at transcribe")
  func retryStartsAtFailedCleanup() {
    var artifacts = fullArtifacts()
    artifacts.cleanupExists = false
    artifacts.summaryCount = 0
    artifacts.noteLink = nil
    let failed = session(pipelineIssues: [
      PipelineIssue(
        stage: "cleanup", kind: .failed, message: "LLM backend call timed out",
        exitClass: "retryable-upstream")
    ])
    let stages = SessionPipeline.stages(session: failed, artifacts: artifacts, now: muchLater)
    #expect(SessionPipeline.retryStart(stages) == .from("cleanup"))
  }

  @Test("retry resumes at summarize when cleanup published")
  func retryStartsAtSummarize() {
    var artifacts = fullArtifacts()
    artifacts.summaryCount = 0
    artifacts.noteLink = nil
    let stages = SessionPipeline.stages(session: session(), artifacts: artifacts, now: muchLater)
    #expect(SessionPipeline.retryStart(stages) == .from("summarize"))
  }

  @Test("retry has nothing to do for a published session, an empty one, or a live one")
  func retryRefusals() {
    let published = SessionPipeline.stages(
      session: session(), artifacts: fullArtifacts(), now: muchLater)
    #expect(SessionPipeline.retryStart(published) == .nothingToRetry)

    let empty = SessionPipeline.stages(
      session: session(), artifacts: emptyTranscriptArtifacts(), now: muchLater)
    #expect(SessionPipeline.retryStart(empty) == .emptyTranscript)

    let live = SessionPipeline.stages(
      session: session(state: .active), artifacts: SessionArtifacts(), now: justAfter)
    #expect(SessionPipeline.retryStart(live) == .live)
  }
}

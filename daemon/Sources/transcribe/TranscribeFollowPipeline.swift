import EarsCore
import EarsDataStore
import EarsTranscribeKit
import Foundation

/// `transcribe --follow`'s pipeline, per `docs/specs/transcribe.md`'s
/// "Streaming mode": attach to a live source — resolved through the meeting
/// currently capturing it, since live capture writes only under
/// `meetings/<id>/sources/<source>/` — tail its index for newly-written
/// `chunk`/`vad` events (byte-offset tail, no re-polling of the whole file —
/// ``IndexTailReader``), decode incrementally through a real
/// ``StreamingTranscriber``, and emit finalised segments to three sinks:
///
/// 1. **stdout**, one segment per line (`--json` for the live feed's exact
///    `segment`-event JSON shape), written unbuffered so a piped consumer
///    sees each segment promptly;
/// 2. **the session transcript file** — the *same* Markdown + JSON-sidecar
///    pair batch mode writes (``TranscriptAssembly``/``TranscriptRenderer``,
///    same ``OutputPathResolution`` paths), atomically rewritten on every
///    commit so the on-disk file is complete and correctly formed at any
///    instant, including when the session closes;
/// 3. **the daemon's live feed**, via the `segment.publish` control-socket
///    command — best-effort per the spec's "notification only" rule: a
///    publish failure is logged and never aborts the run or drops the
///    on-disk write. Disk is the durable copy.
///
/// ## Two-pass finalization (and where each pure piece plugs in)
///
/// Audio lands from finalized chunks and flows through a fixed-cadence
/// ``StepBatcher`` into cheap, low-latency **partial** decode steps (their
/// own threaded ``DecoderState``). Partials are mutable by contract: they
/// exist to keep decode work off the finalization critical path, and their
/// accumulated text doubles as the committed-text *fallback* if a window's
/// finalization decode throws — nothing user-visible is built on them
/// directly. When a window boundary is reached — a VAD silence span from the
/// index, a capture gap, the window cap, or end of stream — the window's
/// audio is re-decoded **once** with maximum look-ahead (the whole window in
/// one `step`, its own continuity state threaded across windows, trailing
/// silence appended per the TDT final-word-drop requirement), and that text
/// is committed through ``StreamingDelta``: the append-only cursor
/// guarantees committed output never retracts, and a trailing partial token
/// at a cap-forced (unconfirmed) boundary is held back and joins the *next*
/// segment rather than emitting a cut word. This is deliberately not the
/// re-transcribe-overlapping-windows-and-de-duplicate anti-pattern the spec
/// names: every sample is partial-decoded once and final-decoded once, with
/// no overlap and no dedup heuristics.
///
/// Windows fully covered by VAD silence (no `speech` span overlap, when VAD
/// events exist at all) are dropped without decoding, mirroring batch mode's
/// silence skipping.
///
/// ## Exit
///
/// Runs until `isStopped` flips (wired to SIGINT/SIGTERM by
/// ``FollowRuntime``; the seam is injected so tier-1 tests stop it
/// directly). On stop, the remaining window is finalised as a confirmed
/// boundary (end of stream *is* a boundary) and ``StreamingDelta/finish()``
/// flushes any held-back partial as a final commit — except a trailing
/// U+FFFD, which is discarded (see that type's doc for the decision). Exit
/// is non-zero only for setup failures (no live meeting capturing the
/// source, non-streaming backend, model load) or a final transcript write
/// that never succeeded.
/// Exiting when the source's *session* closes arrives with `--session`
/// support (deferred alongside batch mode's own `--session` flag, per
/// `TranscribeRangeResolution`'s doc comment) — until then, follow runs
/// until signalled.
///
/// Same tier split as ``TranscribePipeline``: this type takes already-
/// resolved values and injected seams so it is tier-1 testable against a
/// fixture source directory that grows mid-run, with no daemon and no real model;
/// ``FollowRuntime`` owns real config/environment/signal wiring.
enum TranscribeFollowPipeline {
  struct Inputs: Sendable {
    /// The source id to follow (`--follow <source>`).
    var source: String
    /// Emit JSON segment lines (`--json`) instead of plain text.
    var json: Bool
    /// `--out` override for the transcript path.
    var out: String?
  }

  /// Everything real production code has to fake to test this pipeline,
  /// plus the streaming tuning knobs (fixed here rather than CLI flags —
  /// they are implementation cadence, not user-facing behaviour).
  struct Dependencies: Sendable {
    var clock: any NowProviding
    var transcriberFactory: @Sendable () throws -> any Transcriber
    var loadOptions: LoadOptions
    var readerFactory: ChunkFileReaderFactory
    /// Fixed partial-step cadence fed to ``StepBatcher``.
    var stepSeconds: Double
    /// Cap on one finalization window. With `finalizePadSeconds` added it
    /// must stay under the ~15 s stateful decode window
    /// (`ParakeetTranscriber.maxStepFrameCount`).
    var maxWindowSeconds: Double
    /// Minimum VAD silence span treated as a natural-pause boundary.
    var minSilenceSeconds: Double
    /// Trailing silence appended to each finalization decode so the TDT
    /// decoder doesn't drop the final word (FluidAudio issue #562).
    var finalizePadSeconds: Double
    /// How long to wait when the tail has no new events.
    var pollInterval: Duration
    var sleep: @Sendable (Duration) async -> Void
    /// Checked once per loop iteration; wired to SIGINT/SIGTERM in
    /// production, flipped directly by tests.
    var isStopped: @Sendable () -> Bool
    /// One finalised-segment line, written and flushed immediately.
    var writeStdoutLine: @Sendable (String) -> Void
    /// Best-effort live-feed publish (must swallow its own failures).
    var publishSegment: @Sendable (EarsEvent) async -> Void
    var log: @Sendable (String) -> Void
    var writeStderr: @Sendable (String) -> Void

    /// The real wiring: ``ParakeetTranscriber``, real chunk decoding, real
    /// signals/stdout, and a ``SegmentEventPublisher`` for the live feed.
    static func production(
      loadOptions: LoadOptions,
      publisher: SegmentEventPublisher,
      isStopped: @escaping @Sendable () -> Bool,
      onError: (@Sendable (String) -> Void)? = nil
    ) -> Dependencies {
      Dependencies(
        clock: SystemClock(),
        transcriberFactory: { ParakeetTranscriber() },
        loadOptions: loadOptions,
        readerFactory: AVFoundationChunkFileReader.make,
        stepSeconds: 2,
        maxWindowSeconds: 12,
        minSilenceSeconds: 0.6,
        finalizePadSeconds: 0.5,
        pollInterval: .milliseconds(250),
        sleep: { duration in try? await Task.sleep(for: duration) },
        isStopped: isStopped,
        writeStdoutLine: { line in
          FileHandle.standardOutput.write(Data((line + "\n").utf8))
        },
        publishSegment: { event in await publisher.publish(event) },
        log: { message in
          FileHandle.standardError.write(Data(("transcribe: " + message + "\n").utf8))
        },
        writeStderr: { line in
          FileHandle.standardError.write(Data((line + "\n").utf8))
          onError?(line)
        }
      )
    }
  }

  static func run(
    inputs: Inputs,
    dataRoot: URL,
    outputRoot: URL,
    backendName: String,
    dependencies: Dependencies
  ) async -> Int32 {
    let sourceID = SourceID(inputs.source)

    // Live capture is meeting-scoped (a CaptureActor's data root is its
    // meeting's directory), so a live tail must resolve the source through
    // the meeting currently capturing it. The legacy global ring
    // (`<data-root>/sources/`) is never written by a live capture and
    // deliberately not consulted: attaching to it would tail a dead index
    // forever with no output and no error.
    let liveMeetings = MeetingStore.readAll(dataRoot: dataRoot).filter { meeting in
      meeting.state != .ended && meeting.sources.contains(sourceID)
    }
    guard let meeting = liveMeetings.max(by: { $0.started < $1.started }) else {
      dependencies.writeStderr(
        "error: source '\(sourceID.rawValue)' is not live: no active meeting is capturing it "
          + "(start one with `ears meeting start --source \(sourceID.rawValue)`)")
      return 1
    }
    let meetingRoot = DataStoreLayout.meetingDirectory(dataRoot: dataRoot, meetingID: meeting.id)

    let sourceDirectory = DataStoreLayout.sourceDirectory(
      dataRoot: meetingRoot, sourceID: sourceID)
    guard FileManager.default.fileExists(atPath: sourceDirectory.path) else {
      dependencies.writeStderr(
        "error: source '\(sourceID.rawValue)' is claimed by meeting '\(meeting.id)' "
          + "but no data found under \(sourceDirectory.path)")
      return 1
    }
    dependencies.log(
      "attaching to meeting '\(meeting.id)' (\(meeting.title)) for source '\(sourceID.rawValue)'")

    let descriptor: SourceDescriptor
    do {
      descriptor = try SourceMetaStore.read(sourceID: sourceID, dataRoot: meetingRoot)
    } catch {
      dependencies.writeStderr(
        "error: failed to read source metadata for '\(sourceID.rawValue)': \(error)")
      return 1
    }

    let transcriber: any Transcriber
    do {
      transcriber = try dependencies.transcriberFactory()
      try transcriber.load(dependencies.loadOptions)
    } catch {
      dependencies.writeStderr("error: failed to load transcriber: \(error)")
      return 1
    }
    guard let streaming = transcriber as? any StreamingTranscriber else {
      dependencies.writeStderr(
        "error: backend '\(transcriber.info.name)' does not support streaming "
          + "(--follow requires a StreamingTranscriber)")
      return 1
    }

    let run = FollowRun(
      inputs: inputs,
      dataRoot: meetingRoot,
      outputRoot: outputRoot,
      backendName: backendName,
      dependencies: dependencies,
      sourceID: sourceID,
      asrSampleRate: descriptor.asrSampleRate,
      streaming: streaming
    )
    return await run.run()
  }
}

/// One `--follow` invocation's mutable state and loop. A plain class (not an
/// actor): everything runs on the single pipeline task, so there is no
/// concurrent access to guard — the async seams (`sleep`, `publishSegment`)
/// are the only suspension points and never re-enter this object.
private final class FollowRun {
  private let inputs: TranscribeFollowPipeline.Inputs
  private let dataRoot: URL
  private let dependencies: TranscribeFollowPipeline.Dependencies
  private let sourceID: SourceID
  private let asrSampleRate: Int
  private let streaming: any StreamingTranscriber
  private let speaker: String
  private let followStart: Instant
  private let sessionID: String
  private let paths: OutputPathResolution.Paths
  private let modelInfo: TranscriptModelInfo

  private var tail: IndexTailReader
  private var vadTail: VADSegmentTailReader
  private var batcher: StepBatcher
  private var delta = StreamingDelta()
  private var partialState = DecoderState()
  private var finalState = DecoderState()

  /// The current finalization window: samples not yet committed, starting
  /// at `windowStart`. Chunk audio is length-normalized to its indexed span
  /// on append (see `appendChunkAudio`), so the sample count and the event
  /// timeline agree exactly and `windowEnd` is pure derived state.
  private var windowSamples: [Float] = []
  private var windowStart: Instant?
  private var windowEnd: Instant? {
    windowStart.map { $0.advanced(by: Double(windowSamples.count) / Double(asrSampleRate)) }
  }

  /// The cheap-pass text accumulated for the current window — the committed
  /// -text fallback if the finalization decode fails (see the type doc).
  private var partialHypothesis = ""
  /// The cumulative final-pass stream text, fed to ``StreamingDelta``.
  private var finalHypothesis = ""
  /// VAD speech spans not yet consumed by a finalized window — the
  /// silence-skip check's evidence that a window has speech at all.
  private var speechSpans: [TimeRange] = []
  private var sawVadEvents = false
  /// Natural-pause boundary instants (VAD silence starts, gap starts)
  /// waiting for their audio to land. All are *confirmed* boundaries;
  /// cap-forced (unconfirmed) cuts are synthesized in
  /// ``processDueBoundaries()`` instead of queued here.
  private var pendingBoundaries: [Instant] = []

  private var committedSegments: [Segment] = []
  private var speechSeconds: Double = 0
  private var latestBoundary: Instant
  private var transcriptWriteFailed = false

  init(
    inputs: TranscribeFollowPipeline.Inputs,
    dataRoot: URL,
    outputRoot: URL,
    backendName: String,
    dependencies: TranscribeFollowPipeline.Dependencies,
    sourceID: SourceID,
    asrSampleRate: Int,
    streaming: any StreamingTranscriber
  ) {
    self.inputs = inputs
    self.dataRoot = dataRoot
    self.dependencies = dependencies
    self.sourceID = sourceID
    self.asrSampleRate = asrSampleRate
    self.streaming = streaming
    self.speaker = TranscriptAssembly.speakerLabel(for: sourceID)

    let followStart = dependencies.clock.now()
    self.followStart = followStart
    self.latestBoundary = followStart
    self.sessionID = OutputPathResolution.sessionIdentifier(
      requestedStart: followStart, sourceIDs: [sourceID])
    self.paths = OutputPathResolution.resolve(
      outputRoot: outputRoot, requestedStart: followStart, sourceIDs: [sourceID],
      explicitOut: inputs.out)
    self.modelInfo = TranscriptModelInfo(
      name: streaming.info.name, backend: backendName, version: streaming.info.version)
    self.batcher = StepBatcher(
      stepFrameCount: max(1, Int(dependencies.stepSeconds * Double(asrSampleRate))))
    // Attach semantics: only index lines appended after this instant are
    // processed — a follower that attaches late gets no replay, matching
    // the live feed's own contract; the batch tool covers the past.
    self.tail = IndexTailReader(
      fileURL: DataStoreLayout.structuralIndexFile(dataRoot: dataRoot, sourceID: sourceID),
      startAtEnd: true)
    self.vadTail = VADSegmentTailReader(
      directory: DataStoreLayout.vadDirectory(dataRoot: dataRoot, sourceID: sourceID),
      startAtEnd: true)
  }

  func run() async -> Int32 {
    dependencies.log(
      "following '\(sourceID.rawValue)' from \(FilenameTimestampCodec.string(for: followStart)); "
        + "transcript: \(paths.markdown.path)")

    let log = dependencies.log
    while true {
      let stopped = dependencies.isStopped()
      let onMalformed: (String) -> Void = { line in
        log("skipping malformed index line: \(line)")
      }
      let structuralEvents = tail.readNewEvents(onMalformed: onMalformed)
      let vadEvents = vadTail.readNewEvents(onMalformed: onMalformed)
      for event in structuralEvents {
        await ingest(event)
      }
      for event in vadEvents {
        await ingest(event)
      }
      await processDueBoundaries()

      if stopped {
        await finishStream()
        break
      }
      if structuralEvents.isEmpty && vadEvents.isEmpty {
        await dependencies.sleep(dependencies.pollInterval)
      }
    }

    writeTranscript()
    if transcriptWriteFailed {
      dependencies.writeStderr("error: failed to write transcript to \(paths.markdown.path)")
      return 1
    }
    dependencies.log(
      "run.summary: segments=\(committedSegments.count) "
        + "speech_seconds=\(speechSeconds) "
        + "duration_seconds=\(latestBoundary.interval(since: followStart)) "
        + "output=\(paths.markdown.path)"
    )
    return 0
  }

  // MARK: - Event ingestion

  private func ingest(_ event: IndexEvent) async {
    switch event {
    case .chunk(let start, let end, let file, _):
      guard end > followStart else { return }
      await appendChunkAudio(start: start, end: end, file: file)
    case .vad(let state, let start, let end):
      sawVadEvents = true
      switch state {
      case .speech:
        speechSpans.append(TimeRange(start: start, end: end))
      case .silence:
        if end.interval(since: start) >= dependencies.minSilenceSeconds, start > followStart {
          pendingBoundaries.append(start)
        }
      }
    case .gap(let start, _, let reason):
      // Known-missing audio is a hard natural boundary, logged but not
      // fatal — matching batch mode's "honour gap events" behaviour.
      dependencies.log("capture gap on '\(sourceID.rawValue)' (\(reason))")
      if start > followStart {
        pendingBoundaries.append(start)
      }
    case .evict:
      break  // Eviction targets hours-old chunks; a live tail never needs them.
    }
  }

  private func appendChunkAudio(start: Instant, end: Instant, file: String) async {
    let filename = URL(fileURLWithPath: file).lastPathComponent
    let fileURL = DataStoreLayout.asrDirectory(dataRoot: dataRoot, sourceID: sourceID)
      .appendingPathComponent(filename)

    var samples: [Float]
    let clippedStart = max(start, followStart)
    let nominalFrames = max(
      0, Int((end.interval(since: clippedStart) * Double(asrSampleRate)).rounded()))
    guard nominalFrames > 0 else { return }
    do {
      let reader = try dependencies.readerFactory(fileURL)
      let skipFrames = min(
        reader.frameCount,
        max(0, Int((clippedStart.interval(since: start) * Double(asrSampleRate)).rounded())))
      guard skipFrames < reader.frameCount else { return }
      samples = try reader.read(frames: skipFrames..<reader.frameCount)
    } catch {
      dependencies.log("failed to read chunk \(filename): \(error); treating as a gap")
      if let windowEnd { await finalizeWindow(at: windowEnd, confirmed: true) }
      windowStart = nil
      return
    }
    guard !samples.isEmpty else { return }

    // Normalize the decoded length to the chunk's indexed span: a real
    // AAC/Opus decode can come back a few hundred ms short or long of the
    // nominal duration (priming/padding), and the window's instant↔sample
    // mapping must stay exact against the *event timeline* every boundary
    // instant lives on. A short decode is padded with silence, a long one
    // trimmed — per-chunk, so the discrepancy never accumulates.
    if samples.count > nominalFrames {
      samples.removeLast(samples.count - nominalFrames)
    } else if samples.count < nominalFrames {
      samples.append(contentsOf: [Float](repeating: 0, count: nominalFrames - samples.count))
    }

    // A discontinuity between the last landed audio and this chunk is an
    // implicit gap: close the window at the old edge *now*, then restart
    // the window at this chunk's start — the window's sample-to-instant
    // mapping assumes contiguous audio, so the hole must not be spanned.
    if let windowEnd, clippedStart.interval(since: windowEnd) > 0.25 {
      await finalizeWindow(at: windowEnd, confirmed: true)
      windowStart = nil
    }
    if windowStart == nil {
      windowStart = clippedStart
    }
    windowSamples.append(contentsOf: samples)

    runPartialPass(AudioBuffer(samples: samples, sampleRate: asrSampleRate))
  }

  /// The cheap low-latency pass: fixed-cadence steps through the streaming
  /// decoder, threading `partialState`. Failures here never fail the run —
  /// the finalization pass re-decodes everything that matters. The
  /// accumulated hypothesis is a best-effort, window-granular fallback: the
  /// batcher's cadence is not boundary-aligned, so when one window
  /// finalizes in several slices, the whole window's partial text backs the
  /// *first* slice's decode failure and later slices fall back to nothing —
  /// an accepted approximation for what is already a degraded error path.
  private func runPartialPass(_ buffer: AudioBuffer) {
    for step in batcher.append(buffer) {
      do {
        let segments = try streaming.step(step, state: &partialState)
        let text = segments.map(\.text).joined(separator: " ")
        guard !text.isEmpty else { continue }
        partialHypothesis =
          partialHypothesis.isEmpty ? text : partialHypothesis + " " + text
      } catch {
        dependencies.log("partial decode step failed: \(error)")
      }
    }
  }

  // MARK: - Finalization

  /// Finalizes every boundary whose audio has fully landed, oldest first,
  /// then enforces the window cap.
  private func processDueBoundaries() async {
    pendingBoundaries.sort { $0 < $1 }
    while let boundary = pendingBoundaries.first {
      guard let start = windowStart, let end = windowEnd else { break }
      if boundary <= start {
        pendingBoundaries.removeFirst()
        continue
      }
      // A pause-free run longer than the cap (a 30 s chunk can land far
      // more than `maxWindowSeconds` of audio at once) is cut at the cap
      // *before* the natural boundary is honoured — a finalization decode
      // must never exceed the model's stateful window, or the streaming
      // backend refuses it (`stepTooLong`) and the window degrades to its
      // fallback text.
      if boundary.interval(since: start) > dependencies.maxWindowSeconds {
        guard end.interval(since: start) >= dependencies.maxWindowSeconds else { break }
        await finalizeWindow(
          at: start.advanced(by: dependencies.maxWindowSeconds), confirmed: false)
        continue
      }
      guard boundary <= end else { break }
      pendingBoundaries.removeFirst()
      await finalizeWindow(at: boundary, confirmed: true)
    }

    while let start = windowStart, let end = windowEnd,
      end.interval(since: start) >= dependencies.maxWindowSeconds
    {
      // Cap-forced cut: not a natural pause, so the boundary is unconfirmed
      // and StreamingDelta holds back a trailing partial token.
      await finalizeWindow(
        at: start.advanced(by: dependencies.maxWindowSeconds), confirmed: false)
    }
  }

  /// Slices the window at `boundary`, runs the max-look-ahead finalization
  /// decode over the slice, and commits the text. `confirmed` marks a
  /// natural boundary (VAD pause, gap, end of stream): the trailing word is
  /// known-complete, so the whole text emits; a cap-forced boundary leaves
  /// the trailing token held back for the next segment.
  private func finalizeWindow(at boundary: Instant, confirmed: Bool) async {
    guard let start = windowStart, boundary > start else { return }
    let sliceSeconds = boundary.interval(since: start)
    let sliceFrames = min(
      windowSamples.count, max(0, Int((sliceSeconds * Double(asrSampleRate)).rounded())))
    let slice = Array(windowSamples.prefix(sliceFrames))
    windowSamples.removeFirst(sliceFrames)
    windowStart = boundary
    latestBoundary = max(latestBoundary, boundary)

    let sliceRange = TimeRange(start: start, end: boundary)
    // Batch-parity silence skipping: when VAD spans exist and none overlap
    // this slice, drop it without decoding. Without VAD info, decode — a
    // silent decode just returns no text.
    let hadSpeech = !sawVadEvents || speechSpans.contains { $0.overlaps(sliceRange) }
    speechSpans.removeAll { $0.end <= boundary }
    let fallback = partialHypothesis
    partialHypothesis = ""
    guard hadSpeech, !slice.isEmpty else { return }

    speechSeconds += Double(slice.count) / Double(asrSampleRate)

    var decodeSamples = slice
    // Trailing-silence pad (FluidAudio issue #562: the TDT decoder drops
    // the final word without it) — but only at a *confirmed* boundary,
    // where silence genuinely follows (a VAD pause, a gap, end of stream).
    // A cap-forced cut lands mid-speech: injecting fake silence there would
    // thread a phantom pause into `finalState`'s continuity right where the
    // next window resumes mid-utterance, and the held-back-token mechanism
    // already covers the truncated tail.
    if confirmed {
      let padFrames = Int(dependencies.finalizePadSeconds * Double(asrSampleRate))
      decodeSamples.append(contentsOf: [Float](repeating: 0, count: padFrames))
    }

    var text: String
    do {
      let segments = try streaming.step(
        AudioBuffer(samples: decodeSamples, sampleRate: asrSampleRate), state: &finalState)
      text = segments.map(\.text).joined(separator: " ")
    } catch {
      dependencies.log(
        "finalization decode failed (\(error)); committing this window's partial-pass text")
      text = fallback
    }

    await commit(text: text, range: sliceRange, confirmed: confirmed)
  }

  /// Runs `text` through the append-only delta and, if anything newly
  /// emits, appends a committed segment to all three sinks. Committed text
  /// is never retracted or edited afterwards.
  private func commit(text: String, range: TimeRange, confirmed: Bool) async {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
      finalHypothesis = finalHypothesis.isEmpty ? trimmed : finalHypothesis + " " + trimmed
    }
    // A confirmed boundary appends the word-boundary whitespace that lets
    // StreamingDelta emit the final token; an unconfirmed one doesn't, so
    // the trailing token stays held back until the next window confirms it.
    let emitted = delta.advance(confirmed ? finalHypothesis + " " : finalHypothesis)
    await emitSegment(
      text: emitted,
      start: range.start.interval(since: followStart),
      end: range.end.interval(since: followStart))
  }

  private func emitSegment(text: String, start: Double, end: Double) async {
    let segmentText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !segmentText.isEmpty else { return }

    let segment = Segment(start: start, end: end, text: segmentText)
    committedSegments.append(segment)

    let event = EarsEvent.segment(
      SegmentPublishParams(
        session: sessionID, speaker: speaker, start: segment.start, end: segment.end,
        text: segmentText))
    dependencies.writeStdoutLine(stdoutLine(for: segment, event: event))
    writeTranscript()
    // Best-effort, after the durable write: the publisher logs and swallows
    // its own failures per the notification-only rule.
    await dependencies.publishSegment(event)
  }

  private func stdoutLine(for segment: Segment, event: EarsEvent) -> String {
    if inputs.json {
      // The live feed's exact wire shape, one event per line, so a piped
      // consumer and a socket subscriber parse the same JSON.
      let encoder = JSONEncoder()
      if let data = try? encoder.encode(EventFrame(event: event)) {
        return String(decoding: data, as: UTF8.self)
      }
    }
    let time = UTCCalendar.timeOfDay(followStart.advanced(by: segment.start))
    return "[\(time)] \(speaker): \(segment.text)"
  }

  // MARK: - End of stream

  private func finishStream() async {
    // End of stream is a boundary: finalize whatever audio remains as a
    // confirmed cut (the batcher's pending sub-step remainder is the same
    // audio, so it needs no separate flush through the partial pass).
    if let end = windowEnd {
      await finalizeWindow(at: end, confirmed: true)
    }
    // Flush any still-held-back partial as a final commit; a trailing
    // U+FFFD is discarded by StreamingDelta.finish() (documented there).
    let flushed = delta.finish()
    if !flushed.isEmpty {
      let at = latestBoundary.interval(since: followStart)
      await emitSegment(text: flushed, start: at, end: at)
    }
  }

  // MARK: - Transcript file

  /// Atomically rewrites the transcript Markdown + JSON sidecar from every
  /// committed segment — the same document assembly and renderers batch
  /// mode uses, so the on-disk file is byte-compatible with a batch run's
  /// format and always well-formed ("appends" at the content level; atomic
  /// replace at the file level, per the never-half-written rule).
  private func writeTranscript() {
    let requested = TimeRange(start: followStart, end: latestBoundary)
    let document = TranscriptAssembly.assemble(
      sourceIDs: [sourceID],
      transcriptions: [SourceTranscription(sourceID: sourceID, segments: committedSegments)],
      requested: requested,
      sessionIdentifier: sessionID,
      model: modelInfo,
      generated: dependencies.clock.now(),
      speechSeconds: speechSeconds
    )
    do {
      let markdown = TranscriptRenderer.renderMarkdown(document)
      try AtomicFileIO.writeAtomically(to: paths.markdown) { tempURL in
        try markdown.write(to: tempURL, atomically: false, encoding: String.Encoding.utf8)
      }
      let json = TranscriptRenderer.renderJSON(document)
      try AtomicFileIO.writeAtomically(to: paths.sidecar) { tempURL in
        try json.write(to: tempURL, atomically: false, encoding: String.Encoding.utf8)
      }
      transcriptWriteFailed = false
    } catch {
      // Log and keep running: the next commit retries. Only a terminal
      // failure (still failing at exit) fails the run.
      transcriptWriteFailed = true
      dependencies.log("failed to write transcript: \(error)")
    }
  }
}

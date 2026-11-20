import EarsCLISupport
import EarsCore
import EarsDataStore
import EarsDiarizeKit
import EarsLogging
import EarsTranscribeKit
import Foundation

/// `transcribe`'s actual pipeline, per `docs/specs/transcribe.md`'s
/// "Behaviour" section: resolve the requested range and sources, read each
/// source's real captured audio into decoded, natural-pause-segmented
/// slices (``SegmentedAudioReader``, the composition root already merged on
/// this base -- it resolves each source's `meta.toml` for the ASR sample
/// rate and reads the real, codec-decoded `asr/` chunk files itself), run
/// each slice through a ``Transcriber``, merge the results onto one shared
/// timeline (``TranscriptAssembly``), and write the Markdown transcript +
/// JSON sidecar atomically.
///
/// The transcript it writes is an **intermediate**: it lands in the data
/// store (``TranscriptStorePaths``), addressed by session or range-run
/// identifier, never under `output_root`. Publishing — a cleaned transcript
/// at a user-configured path — is `cleanup`'s job.
///
/// Deliberately takes `dataRoot`/`backendName` as plain, already-resolved
/// values rather than reading config/environment itself -- that resolution is
/// ``TranscribeRuntime``'s job (the thin, tier-2/3 glue layer that reads
/// `ProcessInfo.environment`/the home directory/the real config file).
/// Splitting it this way means this type -- everything from "have a data
/// root" onward, which is most of `transcribe`'s actual behaviour -- is
/// directly unit-testable against a fixture data root and an injected fake
/// ``Transcriber`` with no environment-variable or config-file setup at all,
/// per `docs/engineering-practices.md`'s tier-1 "fixture audio store on disk"
/// strategy.
enum TranscribePipeline {
  /// Everything real production code has to fake to test this type: the
  /// wall clock and which ``Transcriber`` to run. `log` is a side-channel
  /// for non-fatal, human-readable notices (the final run summary) --
  /// separate from the hard-failure `writeStderr` path, which always
  /// accompanies a non-zero exit code.
  struct Dependencies: Sendable {
    var clock: any NowProviding
    var transcriberFactory: @Sendable () throws -> any Transcriber
    var loadOptions: LoadOptions
    /// The optional diarization backend (`docs/specs/model-interface.md`'s
    /// `Diarizer`). `nil` ⇒ diarization is off (the default): segments keep
    /// source-only labels, exactly as before. When present, each multi-speaker
    /// far-end source is refined into `Speaker N` (the offline/stabilised pass).
    var diarizerFactory: (@Sendable () throws -> any Diarizer)? = nil
    /// Model/compute selection for the diarizer, resolved from `[diarize]`.
    var diarizerLoadOptions: LoadOptions = LoadOptions()
    var log: @Sendable (String) -> Void
    var writeStderr: @Sendable (String) -> Void
    /// The machine-readable stdout channel. A successful batch run's **final
    /// stdout line is the written transcript's absolute path** — the contract
    /// the daemon's on-end stage chain (`OnClosePipelineRunner`) parses to
    /// feed `cleanup` without re-deriving `OutputPathResolution`'s logic.
    /// Batch stdout carries nothing else (`--follow`'s live segment lines are
    /// a different pipeline). ``TranscribeRuntime`` routes this through the
    /// process's `EarsCLISupport.ResultChannel` — the *only* route to the
    /// real stdout once the channel is active — so the default is a no-op
    /// rather than a direct `FileHandle.standardOutput` write pollution could
    /// share.
    var writeStdout: @Sendable (String) -> Void = { _ in }
    /// Structured headline counts for the final `run.summary` (segments,
    /// words, sources consulted, output path), surfaced so the *log* — not
    /// just the human-readable stdout/stderr line — carries them, and an
    /// empty-but-successful run (`segments=0 words=0`) is distinguishable from
    /// a run that failed (issue #25). Optional: unit tests that only assert
    /// exit codes leave it `nil`.
    var onSummary: (@Sendable ([LogField]) -> Void)? = nil
    /// Emits the `stage.start`/`stage.end` pairs `docs/logging.md` specifies,
    /// so per-stage timing and `rtf` are queryable instead of only whole-run
    /// wall time. Optional: unit tests that don't assert on logging leave it
    /// `nil` and every `measure` call becomes a plain passthrough.
    var spans: StageSpans? = nil

    /// The real backend: ``ParakeetTranscriber``, FluidAudio-backed Parakeet
    /// on the ANE/Metal (`docs/specs/model-interface.md`'s "Backend
    /// 1 -- native"), loaded once per run in ``TranscribePipeline/run``
    /// below with `loadOptions` resolved from `[transcribe].model`/`compute`
    /// config (``TranscribeRuntime``).
    ///
    /// `onError`/`onSummary` are the structured-logging seams
    /// ``TranscribeRuntime`` wires to a ``RunDiagnostics``: `onError` observes
    /// every `error: …` line the pipeline writes to stderr (the last one wins,
    /// becoming the summary's `error` field), `onSummary` receives the final
    /// counts. Both default to `nil`, so this factory behaves exactly as
    /// before for any caller that doesn't need them.
    static func production(
      loadOptions: LoadOptions = LoadOptions(),
      diarizeBackendName: String = "none",
      diarizerLoadOptions: LoadOptions = LoadOptions(),
      onError: (@Sendable (String) -> Void)? = nil,
      onSummary: (@Sendable ([LogField]) -> Void)? = nil,
      spans: StageSpans? = nil
    ) -> Dependencies {
      // One shared ANE gate for both the ASR and diarization backends: the
      // macOS 14 Core ML SIGBUS this serializes against is process-wide, so
      // Parakeet and Sortformer must never run inference concurrently.
      let gate = ANEInferenceGate()
      // The closure is annotated `@Sendable` explicitly: inference does not
      // propagate the optional's `@Sendable` element type through the ternary
      // to a bare closure literal (it does for the direct `transcriberFactory:`
      // argument below, which is why that one needs no annotation).
      let diarizerFactory: (@Sendable () throws -> any Diarizer)? =
        diarizeBackendName == "sortformer"
        ? { @Sendable in SortformerDiarizerBackend(gate: gate) }
        : nil
      return Dependencies(
        clock: SystemClock(),
        transcriberFactory: { ParakeetTranscriber(gate: gate) },
        loadOptions: loadOptions,
        diarizerFactory: diarizerFactory,
        diarizerLoadOptions: diarizerLoadOptions,
        log: { message in
          FileHandle.standardError.write(Data(("transcribe: " + message + "\n").utf8))
        },
        writeStderr: { line in
          FileHandle.standardError.write(Data((line + "\n").utf8))
          onError?(line)
        },
        onSummary: onSummary,
        spans: spans
      )
    }
  }

  struct Inputs: Sendable {
    var last: String?
    var from: String?
    var to: String?
    /// `--session <id>`: union the session's intervals into one transcript
    /// (paused spans are skipped exactly like silence). Mutually exclusive
    /// with every other range flag — `Transcribe` validates that before the
    /// pipeline runs.
    var session: String? = nil
    var sourceIDs: [String]
    var out: String?
    /// `--rereconcile`: re-derive the session's speaker map from its roster
    /// with the current ``RosterReconciler``, ignoring the stored
    /// `[[speaker]]` map even when its `reconciler_version` is current.
    /// Only meaningful with `session` — `Transcribe` validates that.
    var rereconcile: Bool = false
  }

  /// Entry point. `socketPath` (when resolvable) lets a `--session` run
  /// report its lifecycle through the daemon's `job.publish` feed —
  /// best-effort, never load-bearing.
  static func run(
    inputs: Inputs,
    dataRoot: URL,
    backendName: String,
    socketPath: String? = nil,
    dependencies: Dependencies
  ) async -> Int32 {
    guard let sessionID = inputs.session else {
      return await runResolved(
        inputs: inputs, dataRoot: dataRoot, backendName: backendName,
        dependencies: dependencies)
    }
    let job = JobEventPublisher(
      socketPath: socketPath,
      jobID: "transcribe-\(UUID().uuidString.lowercased().prefix(8))",
      sessionID: sessionID,
      log: dependencies.log)
    await job.publish(state: .started)
    let code = await runResolved(
      inputs: inputs, dataRoot: dataRoot, backendName: backendName,
      dependencies: dependencies)
    await job.publish(
      state: code == 0 ? .done : .failed, detail: code == 0 ? nil : "exit \(code)")
    await job.shutdown()
    return code
  }

  private static func runResolved(
    inputs: Inputs,
    dataRoot: URL,
    backendName: String,
    dependencies: Dependencies
  ) async -> Int32 {
    let now = dependencies.clock.now()

    // `--session` resolves to the session's interval union; the raw range
    // flags (`--last`, `--from`/`--to`) resolve to exactly one range.
    let requestedRange: TimeRange
    let intervalRanges: [TimeRange]
    let sessionRecord: Session?
    if let sessionID = inputs.session {
      let session: Session
      do {
        session = try SessionStore.read(sessionID: sessionID, dataRoot: dataRoot)
      } catch {
        dependencies.writeStderr("error: unknown session '\(sessionID)': \(error)")
        return ExitClass.inputMissing.code
      }
      // A still-open interval (session active) reads up to now — "give me
      // what's there so far", matching `--last`'s own "ending now" semantics.
      let ranges = session.intervals.compactMap { interval -> TimeRange? in
        let end = interval.end ?? now
        return interval.start < end ? TimeRange(start: interval.start, end: end) : nil
      }
      guard let first = ranges.first, let last = ranges.last else {
        dependencies.writeStderr("error: session '\(sessionID)' has no non-empty intervals")
        return ExitClass.inputMissing.code
      }
      requestedRange = TimeRange(start: first.start, end: last.end)
      intervalRanges = ranges
      sessionRecord = session
    } else {
      switch TranscribeRangeResolution.resolve(
        last: inputs.last, from: inputs.from, to: inputs.to, now: now
      ) {
      case .success(let value): requestedRange = value
      case .failure(let error):
        // Malformed --last/--from/--to spellings are usage errors.
        dependencies.writeStderr("error: \(error.description)")
        return ExitClass.usage.code
      }
      intervalRanges = [requestedRange]
      sessionRecord = nil
    }

    // A session names its own sources; otherwise --source is required,
    // exactly as before.
    let sourceIDs = sessionRecord?.sources ?? inputs.sourceIDs.map { SourceID($0) }
    guard !sourceIDs.isEmpty else {
      dependencies.writeStderr("error: at least one --source is required (or --session naming one)")
      return ExitClass.usage.code
    }

    // Resolve, per source, which store to read from.
    //
    // A `--session` run consults each source's per-session copy
    // (`sessions/<id>/sources/<source>/`) *and* the global ring
    // (`<data-root>/sources/<source>/`), preferring the per-session copy when
    // it holds chunks and falling back to the ring only where it doesn't
    // (issue #20). It logs both consultations and never fails on a source that
    // exists in neither store — that source simply contributes nothing, with a
    // logged reason, so the session's other sources still transcribe. The raw
    // range path (`--last`/`--from`/`--to`) reads one shared root and keeps
    // the fail-fast "unknown source" guard.
    let plans: [SourceAudioPlan]
    if let sessionID = inputs.session {
      plans = planSessionSources(
        sourceIDs: sourceIDs, sessionID: sessionID, dataRoot: dataRoot,
        intervalRanges: intervalRanges, log: dependencies.log)
    } else {
      // Audio is session-scoped: the ad-hoc flags (--last/--from/--to) have
      // no session context and keep the global root; there is no global audio
      // store any more, so they only find audio a caller staged there
      // deliberately.
      let audioRoot = dataRoot
      // Fail fast on an unknown source before loading the (expensive) ASR
      // model or reading any audio, per docs/specs/transcribe.md: "exits
      // non-zero with a precise error if ... sources are unknown." Checking
      // the source's directory (sources/<id>/) rather than requiring
      // meta.toml specifically: every source earsd has ever started capturing
      // gets this directory (EarsDaemon.init creates it unconditionally), so
      // its presence is the honest "does this source exist at all" signal --
      // a missing meta.toml on an existing directory (a stale capture from
      // before EarsDaemon started writing it) surfaces instead as
      // SegmentedAudioReader's own clear error below, not a misleading
      // "unknown source".
      let reader = SegmentedAudioReader(dataRoot: audioRoot)
      for sourceID in sourceIDs {
        let sourceDirectory = reader.sourceDirectory(for: sourceID)
        guard FileManager.default.fileExists(atPath: sourceDirectory.path) else {
          dependencies.writeStderr(
            "error: unknown source '\(sourceID.rawValue)': no data found under \(sourceDirectory.path)"
          )
          return ExitClass.inputMissing.code
        }
      }
      plans = sourceIDs.map { SourceAudioPlan(sourceID: $0, reader: reader, store: nil) }
    }

    // The run's correlation identifier is resolved up front so every stage
    // record below can carry it as its correlation key, matching the worked
    // example in docs/logging.md: the session id for a `--session` run, a
    // synthesized `<start-timestamp>_<slug>` identifier for a raw range run.
    let runIdentifier =
      sessionRecord?.id
      ?? TranscriptStorePaths.rangeRunIdentifier(
        requestedStart: requestedRange.start, sourceIDs: sourceIDs)

    // Optional per-session vocabulary, keyed by session id by convention:
    // `<data-root>/vocab/<session-id>.txt`. Parsed terms feed the
    // ``TranscribeContext`` handed to each transcribe call; absent file (or a
    // raw range run) means no vocabulary, exactly as before.
    var vocabulary: [String] = []
    if let sessionID = inputs.session {
      let vocabURL =
        dataRoot
        .appendingPathComponent("vocab")
        .appendingPathComponent("\(sessionID).txt")
      if let content = try? String(contentsOf: vocabURL, encoding: .utf8) {
        vocabulary = VocabFile.parse(content)
        dependencies.log(
          "vocab: merged \(vocabulary.count) terms from \(vocabURL.path)")
      }
    }
    let transcribeContext = TranscribeContext(vocabulary: vocabulary)

    let transcriber: any Transcriber
    do {
      transcriber = try await measure(
        dependencies.spans, "model_load", session: runIdentifier,
        fields: [LogField("backend", .string(backendName))]
      ) {
        let loaded = try dependencies.transcriberFactory()
        try loaded.load(dependencies.loadOptions)
        return loaded
      }
    } catch {
      dependencies.writeStderr("error: failed to load transcriber: \(error)")
      return ExitClass.stageFailed.code
    }

    // Optional diarizer (`[diarize].backend`). Loading it is best-effort and
    // never fatal: a diarization failure degrades to source-only labels rather
    // than failing the whole transcript (the ASR output is the load-bearing
    // artifact). A `nil` factory means diarization is off.
    var diarizer: (any Diarizer)?
    if let factory = dependencies.diarizerFactory {
      do {
        diarizer = try await measure(
          dependencies.spans, "diarizer_load", session: runIdentifier
        ) {
          let loaded = try factory()
          try loaded.load(dependencies.diarizerLoadOptions)
          return loaded
        }
      } catch {
        dependencies.log(
          "diarizer.load failed: \(error); continuing without diarization")
        diarizer = nil
      }
    }

    var transcriptions: [SourceTranscription] = []
    // Per-source speaker spans from the offline diarization pass, on the shared
    // (range-relative) timeline; empty when diarization is off or a source is
    // single-speaker.
    var diarization: [SourceID: [SpeakerSpan]] = [:]
    var speechSeconds: Double = 0
    // Per-source read outcome, for the segments=0 reason lines below.
    var readOutcomes: [ReadOutcome] = []

    for plan in plans {
      let sourceID = plan.sourceID
      // One read per interval: a paused span is simply never read, so it is
      // provably absent from the output, exactly like silence. A session
      // source with no resolved store (`reader == nil`) contributes nothing.
      var slices: [AudioSlice] = []
      var chunksInRange = 0
      var speechIntervals = 0
      if let reader = plan.reader {
        for range in intervalRanges {
          do {
            let report = try reader.read(source: sourceID, range: range)
            slices.append(contentsOf: report.slices)
            chunksInRange += report.chunksInRange
            speechIntervals += report.speechIntervals
            // A chunk that wouldn't open/decode (e.g. a Bluetooth-rate-switch
            // -poisoned m4a `ExtAudioFileOpenURL` refuses) is skipped by the
            // reader and reported here, per-chunk, so it degrades only its own
            // span — the run continues and the surrounding audio still
            // transcribes, instead of one opaque stderr line aborting six
            // sessions (all-ears issue #26).
            for unreadable in report.unreadableChunks {
              dependencies.log(
                "chunk.unreadable: source=\(sourceID.rawValue) file=\(unreadable.file) "
                  + "error=\(unreadable.error)")
            }
          } catch {
            dependencies.writeStderr(
              "error: failed to read audio for source '\(sourceID.rawValue)': \(error)")
            return ExitClass.inputMissing.code
          }
        }
      }
      readOutcomes.append(
        ReadOutcome(
          sourceID: sourceID, storeExists: plan.reader != nil, chunks: chunksInRange,
          speech: speechIntervals, slices: slices.count))

      var segments: [Segment] = []
      let sliceAudioSeconds = slices.reduce(0.0) { $0 + $1.audio.duration }
      // `Transcriber.transcribe` is a plain synchronous, throwing call
      // (docs/specs/model-interface.md's base protocol). ParakeetTranscriber
      // bridges FluidAudio's async API with a blocking semaphore inside a
      // detached Task (see that type's doc comment for exactly when that
      // bridge is and isn't safe): it is safe here because `transcribe` is
      // a single-shot batch CLI process running one command to completion
      // on its own cooperative-thread-pool task, not a long-lived,
      // multi-actor runtime -- and this loop calls
      // `transcribe(_:context:)` sequentially, never from inside a
      // spawned concurrent `Task`, so the blocking wait here cannot starve
      // other in-flight work. If sources/slices are ever parallelised with
      // `withThrowingTaskGroup`, a blocking call from inside each spawned
      // Task would risk exhausting the limited cooperative thread pool and
      // should move to a genuinely async transcribe API or a dedicated
      // thread instead. The `measure` wrapper adds no concurrency: it awaits
      // the body inline on this same task.
      do {
        segments = try await measure(
          dependencies.spans, "asr", session: runIdentifier,
          audioSeconds: sliceAudioSeconds,
          fields: [
            LogField("source", .string(sourceID.rawValue)),
            LogField("slices", .int(slices.count)),
          ]
        ) {
          var shiftedSegments: [Segment] = []
          for slice in slices {
            // Segment.start/end are relative to the audio buffer a Transcriber
            // decoded (its own doc comment), i.e. relative to *this slice*'s
            // start -- not the overall requested range. Shifting by the
            // slice's own offset from the range start puts every source's
            // segments on one shared timeline before TranscriptAssembly merges
            // them, per docs/specs/transcribe.md's "merge sources on a shared
            // timeline" step.
            let sliceOffset = slice.range.start.interval(since: requestedRange.start)
            let sliceSegments = try transcriber.transcribe(
              slice.audio, context: transcribeContext)
            for segment in sliceSegments {
              shiftedSegments.append(shifted(segment, by: sliceOffset))
            }
          }
          return shiftedSegments
        }
      } catch {
        dependencies.writeStderr(
          "error: transcription failed for source '\(sourceID.rawValue)': \(error)")
        return ExitClass.stageFailed.code
      }
      speechSeconds += sliceAudioSeconds

      transcriptions.append(SourceTranscription(sourceID: sourceID, segments: segments))

      // Diarization refines a *multi-speaker far-end* source into `Speaker N`;
      // it never runs on the mic (you) or an already-per-participant browser
      // stream (single speaker each). A failure here is logged and skipped, so
      // the source keeps its source-only label rather than failing the run.
      if let diarizer, shouldDiarize(sourceID), !slices.isEmpty {
        do {
          let spans = try await measure(
            dependencies.spans, "diarize", session: runIdentifier,
            audioSeconds: sliceAudioSeconds,
            fields: [LogField("source", .string(sourceID.rawValue))]
          ) {
            try diarizeSource(
              slices: slices, requestedStart: requestedRange.start, diarizer: diarizer)
          }
          if !spans.isEmpty { diarization[sourceID] = spans }
        } catch {
          dependencies.log(
            "diarize failed for source '\(sourceID.rawValue)': \(error)")
        }
      }
    }

    // A browser source that repeats the mic is the user's own outgoing audio,
    // captured a second time; its turns would duplicate every `You` turn under
    // somebody else's name. Leave it out before labels are derived, so the
    // roster is reconciled against the sources that are really remote.
    //
    // When the copy carries clearly more speech than the mic, the copy is the
    // better record of the user: it stands in for the mic over the span it
    // covers, labelled `You`, and the mic's turns inside that span go instead.
    let micResolution = MicDuplicateSources.resolve(transcriptions)
    // Every source the roster must not name: the dropped copies and the one
    // standing in for the mic.
    let micDuplicates = Set(
      micResolution.dropped + [micResolution.micReplacement].compactMap { $0 })
    if !micResolution.isEmpty {
      let dropped = Set(micResolution.dropped)
      transcriptions.removeAll { dropped.contains($0.sourceID) }
      diarization = diarization.filter { !micDuplicates.contains($0.key) }
      if let span = micResolution.replacedSpan,
        let micIndex = transcriptions.firstIndex(where: { $0.sourceID == SourceID("mic") })
      {
        transcriptions[micIndex].segments.removeAll { span.contains($0.start) }
      }
      dependencies.log(
        "left out \(dropped.count) browser source(s) that repeat the mic: "
          + dropped.map(\.rawValue).sorted().joined(separator: ", ")
          + (micResolution.micReplacement.map {
            "; \($0.rawValue) carries more of the user's speech than the mic and replaces it"
          } ?? ""))
    }

    let generated = dependencies.clock.now()
    let modelInfo = TranscriptModelInfo(
      name: transcriber.info.name, backend: backendName, version: transcriber.info.version)

    // Speaker labels come from the session's *reconciled* map, not from the
    // roster's raw bindings: `RosterReconciler` has already dropped the
    // impossible ones and filled what the roster determines by elimination,
    // and re-deriving it here from `attendee.source` would reinstate exactly
    // the bindings it rejected. Several sources naming one speaker is normal
    // and intended — turns group by resolved label, so a participant split
    // across an identity upgrade reassembles into one speaker.
    //
    // A session with no map — or one whose map an *older* reconciler wrote —
    // is reconciled here instead. That covers every session captured before
    // reconciliation existed, and every session reconciled before the latest
    // fix: re-transcribing one applies the current invariants and repairs its
    // labels retroactively. It is only possible because the derivation is a
    // pure function of the roster, so running it late gives the same answer
    // as running it at session end would today. The re-derived map is used
    // for this run, never written back — `session.toml` stays the daemon's
    // record of what its own reconciliation concluded.
    var reconciled: RosterReconciler.Outcome? = nil
    if let sessionRecord, !sessionRecord.attendees.isEmpty,
      inputs.rereconcile || sessionRecord.speakers.isEmpty
        || sessionRecord.reconcilerVersion < RosterReconciler.version
        || !micDuplicates.isEmpty
    {
      // The attribution log's binding hints feed the re-derivation exactly as
      // they feed the daemon's own session.end reconciliation: sources are
      // opaque track handles, and the log carries links the roster's single
      // `source` field per attendee lost. Best-effort — no log, no hints.
      let attributionURL = SessionAttributionLog.fileURL(
        dataRoot: dataRoot, sessionID: sessionRecord.id)
      let attributionText = try? String(contentsOf: attributionURL, encoding: .utf8)
      let outcome = RosterReconciler.reconcile(
        attendees: sessionRecord.attendees,
        sources: sessionRecord.sources.filter { !micDuplicates.contains($0) },
        sessionStart: sessionRecord.started,
        hints: attributionText.map { AttributionBindingHints.parse(jsonl: $0) } ?? [],
        speech: attributionText.map { AttributionBindingHints.speechEvidence(jsonl: $0) })
      reconciled = outcome
      let reason =
        inputs.rereconcile
        ? "re-reconciliation requested (--rereconcile)"
        : sessionRecord.speakers.isEmpty
          ? "no stored speaker map"
          : !micDuplicates.isEmpty
            ? "the stored speaker map names sources that repeat the mic"
            : "stored speaker map is reconciler v\(sessionRecord.reconcilerVersion), "
              + "current is v\(RosterReconciler.version)"
      dependencies.log(
        "session \(sessionRecord.id): \(reason); reconciled the roster into "
          + "\(outcome.speakers.count) speaker(s) with \(outcome.warnings.count) warning(s)")
    }
    // The full rows (name + confidence per source), not a flattened lookup:
    // assembly labels turns from them *and* records them in the sidecar, the
    // one durable trace of a re-derived map (`session.toml` never sees it).
    var speakers = (reconciled?.speakers ?? sessionRecord?.speakers ?? []).filter {
      !micDuplicates.contains($0.source)
    }
    if let replacement = micResolution.micReplacement {
      speakers.append(
        SessionSpeaker(
          source: replacement, name: TranscriptAssembly.speakerLabel(for: SourceID("mic")),
          confidence: .inferred))
    }
    let warnings =
      (reconciled?.warnings ?? sessionRecord?.warnings ?? [])
      + MicDuplicateSources.warnings(for: micResolution)
    // Everyone the roster named, whether or not any audio was matched to them
    // — the fact that survives a total attribution failure. The local
    // participant is marked the way the summarize prompt's own `speakers:`
    // roll call marks them, so both lines speak one vocabulary.
    var derivedTitle: String? = nil
    if let sessionRecord, let reconciled, sessionRecord.hasDefaultTitle,
      let derived = RosterReconciler.derivedTitle(
        attendees: sessionRecord.attendees, localAttendeeID: reconciled.localAttendeeID)
    {
      derivedTitle = derived
      dependencies.log(
        "session \(sessionRecord.id): titling this transcript \"\(derived)\" from the roster; "
          + "the session itself is still named \"\(sessionRecord.title)\"")
    }
    let attendees = RosterReconciler.attendeeNames(
      sessionRecord?.attendees ?? [], localID: reconciled?.localAttendeeID)

    // The chosen lookup order, recorded in frontmatter so a wrong-store read is
    // visible after the fact (issue #20). Only a `--session` run resolves a
    // per-source store; every other path reads one shared root and records
    // nothing here. A source with no store at all is recorded as `none`.
    let audioStores: [TranscriptAudioStore] =
      inputs.session == nil
      ? []
      : plans.map { TranscriptAudioStore(source: $0.sourceID, store: $0.store?.label ?? "none") }

    let document = TranscriptAssembly.assemble(
      sourceIDs: sourceIDs,
      transcriptions: transcriptions,
      requested: requestedRange,
      // A session transcript is keyed by `session:` alone; only a raw range
      // run still carries the synthesized `range_run:` identifier.
      rangeRun: sessionRecord == nil ? runIdentifier : nil,
      session: sessionRecord?.id,
      // The path-template context every downstream stage reads back from the
      // document rather than being told again on the command line, so a
      // manual rerun files exactly where the daemon-spawned run did.
      // A session that ended before reconciliation existed still carries the
      // platform's meeting id as its title, and that title is what every
      // downstream path template interpolates — including the `notes` lookup
      // that has to match a note the user named after a person. Re-deriving
      // it here means re-running the chain over an old session files it under
      // a readable name, the same as a session captured today.
      title: derivedTitle ?? sessionRecord?.title,
      started: sessionRecord?.started ?? requestedRange.start,
      attendees: attendees,
      warnings: warnings,
      speakers: speakers,
      diarization: diarization,
      diarizationBackend: diarizer?.info.name,
      model: modelInfo,
      generated: generated,
      speechSeconds: speechSeconds,
      audioStores: audioStores
    )

    // Intermediates live in the data store, addressed by session (or by
    // range-run identifier); `output_root` is the *published* artifacts' root
    // and this stage never writes there. `--out` still overrides verbatim.
    let paths: TranscriptStorePaths.Paths
    if let out = inputs.out, !out.isEmpty {
      paths = TranscriptStorePaths.explicit(out)
    } else if let sessionRecord {
      paths = TranscriptStorePaths.session(dataRoot: dataRoot, sessionID: sessionRecord.id)
    } else {
      paths = TranscriptStorePaths.rangeRun(dataRoot: dataRoot, runIdentifier: runIdentifier)
    }

    do {
      let markdown = TranscriptRenderer.renderMarkdown(document)
      try AtomicFileIO.writeAtomically(to: paths.markdown) { tempURL in
        try markdown.write(to: tempURL, atomically: false, encoding: String.Encoding.utf8)
      }
      let json = TranscriptRenderer.renderJSON(document)
      try AtomicFileIO.writeAtomically(to: paths.sidecar) { tempURL in
        try json.write(to: tempURL, atomically: false, encoding: String.Encoding.utf8)
      }
    } catch {
      dependencies.writeStderr("error: failed to write transcript: \(error)")
      return ExitClass.stageFailed.code
    }

    // A run that produced no segments is only diagnosable if each source says
    // *why* it was silent — no chunks, chunks-but-silence, or store missing
    // (issue #20). Logged for every path, but it is a session spanning several
    // sources where a one-line-per-source breakdown matters most.
    if document.segments.count == 0 {
      for outcome in readOutcomes {
        // A source with `nil` reason did produce audio slices — the model just
        // returned no text for them; every other case names the missing input.
        let reason =
          SessionAudioResolution.emptyReason(
            storeExists: outcome.storeExists, chunksInRange: outcome.chunks,
            speechIntervals: outcome.speech, sliceCount: outcome.slices)
          ?? "audio produced no segments"
        dependencies.log("run.empty: source=\(outcome.sourceID.rawValue) reason=\(reason)")
      }
    }

    // How many of the session's listed sources actually resolved to a store
    // versus had no data anywhere — so a "successful" empty run is honestly
    // distinguishable from silence (issue #21's "summary honesty":
    // sources-resolved / sources-missing counts). Every non-`--session` path
    // has already fail-fast-rejected unknown sources above, so all its sources
    // are resolved and `sources_missing` is 0.
    let sourcesResolved = readOutcomes.filter { $0.storeExists }.count
    let sourcesMissing = readOutcomes.count - sourcesResolved

    dependencies.log(
      "run.summary: segments=\(document.segments.count) words=\(document.frontmatter.wordCount) "
        + "sources_resolved=\(sourcesResolved) sources_missing=\(sourcesMissing) "
        + "speech_seconds=\(speechSeconds) duration_seconds=\(requestedRange.duration) "
        + "output=\(paths.markdown.path)"
    )
    dependencies.onSummary?([
      LogField("segments", .int(document.segments.count)),
      LogField("words", .int(document.frontmatter.wordCount)),
      LogField("sources", .int(sourceIDs.count)),
      LogField("sources_resolved", .int(sourcesResolved)),
      LogField("sources_missing", .int(sourcesMissing)),
      LogField("speech_seconds", .double(speechSeconds)),
      LogField("duration_seconds", .double(requestedRange.duration)),
      LogField("output", .string(paths.markdown.path)),
    ])

    // The stdout path contract (see Dependencies.writeStdout): last line of a
    // successful run is the transcript path, emitted only after both files
    // are durably written. Re-wrapped and standardized so the emitted line is
    // always an absolute path with no `.`/`..` components — the daemon parses
    // it from a different cwd, where the output root's raw spelling (e.g.
    // `output_root = "."`) means nothing.
    dependencies.writeStdout(URL(fileURLWithPath: paths.markdown.path).standardizedFileURL.path)

    return 0
  }

  /// Where one source's audio is read from for this run: the ``reader`` bound
  /// to the chosen data root (`nil` on a `--session` run when no store holds the
  /// source at all — it then contributes nothing), and, for a `--session` run,
  /// which ``SessionAudioStore`` was chosen (`nil` for every other path).
  private struct SourceAudioPlan {
    let sourceID: SourceID
    let reader: SegmentedAudioReader?
    let store: SessionAudioStore?
  }

  /// One source's read result, kept so a `segments=0` run can name why each
  /// source was silent (issue #20).
  private struct ReadOutcome {
    let sourceID: SourceID
    let storeExists: Bool
    let chunks: Int
    let speech: Int
    let slices: Int
  }

  /// Resolves each session source to a store, logging every consultation.
  ///
  /// For each source it probes both the per-session copy and the global ring
  /// (index-only, no decode), logs what each holds with its concrete path, then
  /// picks the store per ``SessionAudioResolution/chooseStore(session:ring:)``
  /// — per-session chunks preferred, ring fallback. A source found in neither
  /// store gets a `nil` reader (it contributes nothing, with a logged reason at
  /// the end of the run) rather than failing the whole session.
  private static func planSessionSources(
    sourceIDs: [SourceID], sessionID: String, dataRoot: URL, intervalRanges: [TimeRange],
    log: @Sendable (String) -> Void
  ) -> [SourceAudioPlan] {
    let sessionRoot = DataStoreLayout.sessionDirectory(dataRoot: dataRoot, sessionID: sessionID)
    let sessionReader = SegmentedAudioReader(dataRoot: sessionRoot)
    let ringReader = SegmentedAudioReader(dataRoot: dataRoot)

    return sourceIDs.map { sourceID in
      let sessionProbe = summedProbe(sessionReader, source: sourceID, ranges: intervalRanges)
      let ringProbe = summedProbe(ringReader, source: sourceID, ranges: intervalRanges)
      logConsultation(
        session: sessionID, source: sourceID, store: .session,
        path: sessionReader.sourceDirectory(for: sourceID).path, probe: sessionProbe, log: log)
      logConsultation(
        session: sessionID, source: sourceID, store: .ring,
        path: ringReader.sourceDirectory(for: sourceID).path, probe: ringProbe, log: log)

      let chosen = SessionAudioResolution.chooseStore(session: sessionProbe, ring: ringProbe)
      switch chosen {
      case .some(.session):
        log("session \(sessionID) source \(sourceID.rawValue): reading from session store")
        return SourceAudioPlan(sourceID: sourceID, reader: sessionReader, store: .session)
      case .some(.ring):
        log("session \(sessionID) source \(sourceID.rawValue): reading from ring store")
        return SourceAudioPlan(sourceID: sourceID, reader: ringReader, store: .ring)
      case .none:
        log("session \(sessionID) source \(sourceID.rawValue): no audio store found")
        return SourceAudioPlan(sourceID: sourceID, reader: nil, store: nil)
      }
    }
  }

  /// A source's probe summed over every interval range the run reads (a paused
  /// session has several). `sourceExists` is range-independent, so the first
  /// probe's flag stands for the whole source.
  private static func summedProbe(
    _ reader: SegmentedAudioReader, source sourceID: SourceID, ranges: [TimeRange]
  ) -> SegmentedAudioReader.RangeProbe {
    var exists = false
    var chunks = 0
    var speech = 0
    for range in ranges {
      let probe = reader.probe(source: sourceID, range: range)
      exists = exists || probe.sourceExists
      chunks += probe.chunksInRange
      speech += probe.speechIntervals
    }
    return SegmentedAudioReader.RangeProbe(
      sourceExists: exists, chunksInRange: chunks, speechIntervals: speech)
  }

  private static func logConsultation(
    session sessionID: String, source sourceID: SourceID, store: SessionAudioStore, path: String,
    probe: SegmentedAudioReader.RangeProbe, log: @Sendable (String) -> Void
  ) {
    let result =
      probe.sourceExists
      ? "chunks=\(probe.chunksInRange) speech_intervals=\(probe.speechIntervals)"
      : "no data (store missing)"
    log(
      "session \(sessionID) source \(sourceID.rawValue): consulted \(store.label) store at \(path) — \(result)"
    )
  }

  /// Run `body` as a measured stage when a ``StageSpans`` emitter is wired,
  /// otherwise call it directly. Keeping the optionality here rather than at
  /// each call site means instrumenting a stage costs one wrapper and never
  /// changes its control flow — a pipeline built without logging behaves
  /// exactly as it did before.
  private static func measure<T>(
    _ spans: StageSpans?,
    _ stage: String,
    session: String? = nil,
    audioSeconds: Double? = nil,
    fields: [LogField] = [],
    _ body: () async throws -> T
  ) async rethrows -> T {
    guard let spans else { return try await body() }
    return try await spans.measure(
      stage, session: session, audioSeconds: audioSeconds, fields: fields, body: body)
  }

  private static func shifted(_ segment: Segment, by offset: Double) -> Segment {
    var result = segment
    result.start += offset
    result.end += offset
    result.words = segment.words.map { word in
      var shiftedWord = word
      shiftedWord.start += offset
      shiftedWord.end += offset
      return shiftedWord
    }
    return result
  }

  /// Browser platforms whose capture is one *mixed* far-end stream rather than
  /// a stream per participant. Teams hands the extension a single receiver
  /// track carrying everyone (`docs/specs/browser/extension.md` §Teams), so it
  /// is the one `browser:*` source a diarizer has anything to split. Meet and
  /// Zoom arrive already separated and must stay out: splitting one named
  /// participant into `Speaker 1`/`Speaker 2` would destroy a real identity to
  /// invent two fake ones.
  static let mixedBrowserPlatforms: Set<String> = ["teams"]

  /// Which sources the diarizer refines into `Speaker N`. Source-of-origin is
  /// the primary label, so single-speaker sources are left alone: the `mic`
  /// (you) and each per-participant `browser:*` stream (one named speaker each)
  /// are never diarized. Everything else — `system`, `app:*`, `device:*`, and
  /// the mixed browser platforms above — is a potentially multi-speaker far end
  /// worth splitting. (See `docs/plans/diarization-sortformer.md`.)
  static func shouldDiarize(_ sourceID: SourceID) -> Bool {
    let raw = sourceID.rawValue
    if raw == "mic" { return false }
    guard raw.hasPrefix("browser:") else { return true }
    // `browser:<platform>:<track>` — the platform is the middle segment.
    let platform = raw.dropFirst("browser:".count).prefix { $0 != ":" }
    return mixedBrowserPlatforms.contains(String(platform))
  }

  /// Runs the offline diarization pass over one source and returns its speaker
  /// spans on the shared (range-relative) timeline.
  ///
  /// The reader hands back VAD-gated speech slices, not one contiguous buffer.
  /// Diarizing each slice independently would reset `Speaker N` per slice, so
  /// instead the slices are **concatenated** into one buffer (the diarizer sees
  /// only speech, which is what it wants) and diarized in a single call, keeping
  /// speaker identity stable across the whole source. Each returned span, in
  /// concatenated time, is then clipped back to the slice(s) it overlaps and
  /// translated to the slice's real offset from the requested range start — so a
  /// span that would straddle a removed silence gap is split at that gap, which
  /// is the correct behaviour (the gap was silence).
  static func diarizeSource(
    slices: [AudioSlice], requestedStart: Instant, diarizer: any Diarizer
  ) throws -> [SpeakerSpan] {
    struct Placement {
      let concatStart: Double
      let concatEnd: Double
      let realStart: Double
    }
    var samples: [Float] = []
    var placements: [Placement] = []
    var sampleRate = 16_000
    var cursor = 0.0
    for slice in slices {
      sampleRate = slice.audio.sampleRate
      let duration = slice.audio.duration
      placements.append(
        Placement(
          concatStart: cursor,
          concatEnd: cursor + duration,
          realStart: slice.range.start.interval(since: requestedStart)))
      samples.append(contentsOf: slice.audio.samples)
      cursor += duration
    }
    guard !samples.isEmpty else { return [] }

    let rawSpans = try diarizer.diarize(AudioBuffer(samples: samples, sampleRate: sampleRate))

    var spans: [SpeakerSpan] = []
    for span in rawSpans {
      for placement in placements {
        let start = max(span.start, placement.concatStart)
        let end = min(span.end, placement.concatEnd)
        guard end > start else { continue }
        spans.append(
          SpeakerSpan(
            start: placement.realStart + (start - placement.concatStart),
            end: placement.realStart + (end - placement.concatStart),
            speaker: span.speaker))
      }
    }
    return spans.sorted { $0.start < $1.start }
  }
}

import EarsCore
import EarsDataStore
import EarsTranscribeKit
import Foundation

/// `transcribe`'s actual pipeline, per `docs/specs/transcribe.md`'s
/// "Behaviour" section: resolve the requested range and sources, read each
/// source's real ring-buffer audio into decoded, natural-pause-segmented
/// slices (``SegmentedAudioReader``, the composition root already merged on
/// this base -- it resolves each source's `meta.toml` for the ASR sample
/// rate and reads the real, codec-decoded `asr/` chunk files itself), run
/// each slice through a ``Transcriber``, merge the results onto one shared
/// timeline (``TranscriptAssembly``), and write the Markdown transcript +
/// JSON sidecar atomically.
///
/// Deliberately takes `dataRoot`/`outputRoot`/`backendName` as plain,
/// already-resolved values rather than reading config/environment itself --
/// that resolution is ``TranscribeRuntime``'s job (the thin, tier-2/3 glue
/// layer that reads `ProcessInfo.environment`/the home directory/the real
/// config file). Splitting it this way means this type -- everything from
/// "have a data root and an output root" onward, which is most of
/// `transcribe`'s actual behaviour -- is directly unit-testable against a
/// fixture data root and an injected fake ``Transcriber`` with no
/// environment-variable or config-file setup at all, per
/// `docs/engineering-practices.md`'s tier-1 "fixture ring buffer on disk"
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
    var log: @Sendable (String) -> Void
    var writeStderr: @Sendable (String) -> Void

    /// The real backend: ``ParakeetTranscriber``, FluidAudio-backed Parakeet
    /// on the ANE/Metal (`docs/specs/model-interface.md`'s "Backend
    /// 1 -- native"), loaded once per run in ``TranscribePipeline/run``
    /// below with `loadOptions` resolved from `[transcribe].model`/`compute`
    /// config (``TranscribeRuntime``).
    static func production(loadOptions: LoadOptions = LoadOptions()) -> Dependencies {
      Dependencies(
        clock: SystemClock(),
        transcriberFactory: { ParakeetTranscriber() },
        loadOptions: loadOptions,
        log: { message in
          FileHandle.standardError.write(Data(("transcribe: " + message + "\n").utf8))
        },
        writeStderr: { line in
          FileHandle.standardError.write(Data((line + "\n").utf8))
        }
      )
    }
  }

  struct Inputs: Sendable {
    var last: String?
    var from: String?
    var to: String?
    var session: String?
    /// `--meeting <id>`: union the meeting's intervals into one transcript
    /// (paused spans are skipped exactly like silence). Mutually exclusive
    /// with every other range flag — `Transcribe` validates that before the
    /// pipeline runs.
    var meeting: String? = nil
    var sourceIDs: [String]
    var out: String?
  }

  /// Entry point. `socketPath` (when resolvable) lets a `--meeting` run
  /// report its lifecycle through the daemon's `job.publish` feed —
  /// best-effort, never load-bearing.
  static func run(
    inputs: Inputs,
    dataRoot: URL,
    outputRoot: URL,
    backendName: String,
    socketPath: String? = nil,
    dependencies: Dependencies
  ) async -> Int32 {
    guard let meetingID = inputs.meeting else {
      return await runResolved(
        inputs: inputs, dataRoot: dataRoot, outputRoot: outputRoot, backendName: backendName,
        dependencies: dependencies)
    }
    let job = JobEventPublisher(
      socketPath: socketPath,
      jobID: "transcribe-\(UUID().uuidString.lowercased().prefix(8))",
      meetingID: meetingID,
      log: dependencies.log)
    await job.publish(state: .started)
    let code = await runResolved(
      inputs: inputs, dataRoot: dataRoot, outputRoot: outputRoot, backendName: backendName,
      dependencies: dependencies)
    await job.publish(
      state: code == 0 ? .done : .failed, detail: code == 0 ? nil : "exit \(code)")
    await job.shutdown()
    return code
  }

  private static func runResolved(
    inputs: Inputs,
    dataRoot: URL,
    outputRoot: URL,
    backendName: String,
    dependencies: Dependencies
  ) async -> Int32 {
    let now = dependencies.clock.now()

    // `--meeting` resolves to the meeting's interval union; every other
    // flag combination resolves to exactly one range.
    let resolved: TranscribeRangeResolution.Resolved
    let intervalRanges: [TimeRange]
    let meetingRecord: Meeting?
    if let meetingID = inputs.meeting {
      let meeting: Meeting
      do {
        meeting = try MeetingStore.read(meetingID: meetingID, dataRoot: dataRoot)
      } catch {
        dependencies.writeStderr("error: unknown meeting '\(meetingID)': \(error)")
        return 1
      }
      // A still-open interval (meeting active) reads up to now, matching
      // --session's own in-progress semantics.
      let ranges = meeting.intervals.compactMap { interval -> TimeRange? in
        let end = interval.end ?? now
        return interval.start < end ? TimeRange(start: interval.start, end: end) : nil
      }
      guard let first = ranges.first, let last = ranges.last else {
        dependencies.writeStderr("error: meeting '\(meetingID)' has no non-empty intervals")
        return 1
      }
      resolved = TranscribeRangeResolution.Resolved(
        range: TimeRange(start: first.start, end: last.end),
        sourceIDs: meeting.sources,
        vocab: nil,
        sessionIdentifier: meeting.id,
        sessionSlug: meeting.id)
      intervalRanges = ranges
      meetingRecord = meeting
    } else {
      switch TranscribeRangeResolution.resolve(
        last: inputs.last, from: inputs.from, to: inputs.to, session: inputs.session, now: now,
        sessionReader: { id in
          do {
            return .success(try SessionStore.read(sessionID: id, dataRoot: dataRoot))
          } catch {
            return .failure(.unknownSession(id))
          }
        }
      ) {
      case .success(let value): resolved = value
      case .failure(let error):
        dependencies.writeStderr("error: \(error.description)")
        return 1
      }
      intervalRanges = [resolved.range]
      meetingRecord = nil
    }
    let requestedRange = resolved.range

    // Audio is meeting-scoped: `--meeting M` reads it under meetings/M/, and
    // `--session` under meetings/<slug>/ (sessions are materialized with
    // slug = meeting id). Only the audio moves — meeting.toml/session.toml
    // are still read from the global data root above. The ad-hoc flags
    // (--last/--from/--to) have no meeting context and keep the global root;
    // there is no global audio store any more, so they only find audio a
    // caller staged there deliberately.
    let audioRoot: URL
    if let meetingID = inputs.meeting {
      audioRoot = DataStoreLayout.meetingDirectory(dataRoot: dataRoot, meetingID: meetingID)
    } else if let slug = resolved.sessionSlug {
      audioRoot = DataStoreLayout.meetingDirectory(dataRoot: dataRoot, meetingID: slug)
    } else {
      audioRoot = dataRoot
    }

    // --session's sources override any --source flags; otherwise --source
    // is required, exactly as before.
    let sourceIDs = resolved.sourceIDs ?? inputs.sourceIDs.map { SourceID($0) }
    guard !sourceIDs.isEmpty else {
      dependencies.writeStderr("error: at least one --source is required (or --session naming one)")
      return 1
    }

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
    for sourceID in sourceIDs {
      let sourceDirectory = DataStoreLayout.sourceDirectory(dataRoot: audioRoot, sourceID: sourceID)
      guard FileManager.default.fileExists(atPath: sourceDirectory.path) else {
        dependencies.writeStderr(
          "error: unknown source '\(sourceID.rawValue)': no data found under \(sourceDirectory.path)"
        )
        return 1
      }
    }

    let transcriber: any Transcriber
    do {
      transcriber = try dependencies.transcriberFactory()
      try transcriber.load(dependencies.loadOptions)
    } catch {
      dependencies.writeStderr("error: failed to load transcriber: \(error)")
      return 1
    }

    let audioReader = SegmentedAudioReader(dataRoot: audioRoot)
    var transcriptions: [SourceTranscription] = []
    var speechSeconds: Double = 0

    for sourceID in sourceIDs {
      // One read per interval: a paused span is simply never read, so it is
      // provably absent from the output, exactly like silence.
      var slices: [AudioSlice] = []
      for range in intervalRanges {
        do {
          slices.append(contentsOf: try audioReader.slices(source: sourceID, range: range))
        } catch {
          dependencies.writeStderr(
            "error: failed to read audio for source '\(sourceID.rawValue)': \(error)")
          return 1
        }
      }

      var segments: [Segment] = []
      for slice in slices {
        speechSeconds += slice.audio.duration
        // Segment.start/end are relative to the audio buffer a Transcriber
        // decoded (its own doc comment), i.e. relative to *this slice*'s
        // start -- not the overall requested range. Shifting by the
        // slice's own offset from the range start puts every source's
        // segments on one shared timeline before TranscriptAssembly merges
        // them, per docs/specs/transcribe.md's "merge sources on a shared
        // timeline" step.
        let sliceOffset = slice.range.start.interval(since: requestedRange.start)

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
        // thread instead.
        do {
          let sliceSegments = try transcriber.transcribe(slice.audio, context: TranscribeContext())
          for segment in sliceSegments {
            segments.append(shifted(segment, by: sliceOffset))
          }
        } catch {
          dependencies.writeStderr(
            "error: transcription failed for source '\(sourceID.rawValue)': \(error)")
          return 1
        }
      }

      transcriptions.append(SourceTranscription(sourceID: sourceID, segments: segments))
    }

    let generated = dependencies.clock.now()
    let modelInfo = TranscriptModelInfo(
      name: transcriber.info.name, backend: backendName, version: transcriber.info.version)
    let sessionIdentifier =
      resolved.sessionIdentifier
      ?? OutputPathResolution.sessionIdentifier(
        requestedStart: requestedRange.start, sourceIDs: sourceIDs)

    // The meeting roster's name map (attendee source → display name) feeds
    // speaker labels, so real names flow into the transcript directly.
    var speakers: [String: String] = [:]
    if let meetingRecord {
      for attendee in meetingRecord.attendees {
        if let source = attendee.source, let name = attendee.displayName {
          speakers[source.rawValue] = name
        }
      }
    }

    let document = TranscriptAssembly.assemble(
      sourceIDs: sourceIDs,
      transcriptions: transcriptions,
      requested: requestedRange,
      sessionIdentifier: sessionIdentifier,
      meeting: meetingRecord?.id,
      speakers: speakers,
      model: modelInfo,
      generated: generated,
      speechSeconds: speechSeconds
    )

    let paths = OutputPathResolution.resolve(
      outputRoot: outputRoot, requestedStart: requestedRange.start, sourceIDs: sourceIDs,
      explicitOut: inputs.out, sessionSlug: resolved.sessionSlug)

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
      return 1
    }

    dependencies.log(
      "run.summary: segments=\(document.segments.count) words=\(document.frontmatter.wordCount) "
        + "speech_seconds=\(speechSeconds) duration_seconds=\(requestedRange.duration) "
        + "output=\(paths.markdown.path)"
    )

    return 0
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
}

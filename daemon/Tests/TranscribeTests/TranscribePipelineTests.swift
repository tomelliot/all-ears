import EarsCore
import EarsCoreTestSupport
import EarsDataStore
import Foundation
import Testing

@testable import transcribe

/// Fixture-driven, tier-1 coverage of ``TranscribePipeline``: a real data
/// root on disk (`meta.toml`, a real encoded `asr/` chunk file, and a real
/// `index.jsonl` -- exactly what a real `earsd` capture run produces now
/// that ``EarsDaemon`` writes each source's `meta.toml` at construction, see
/// ``writeFixtureSource(sourceID:dataRoot:chunkStart:chunkDuration:vadSpeechStart:vadSpeechEnd:)``'s
/// doc comment) plus an injected ``ScriptedTranscriber`` in place of a real
/// ASR backend, per `docs/engineering-practices.md`'s "fixture audio store
/// on disk" tier-1 strategy: no real FluidAudio/Parakeet model is needed to
/// prove the wiring -- the right range gets read, segments get merged in
/// order, and the transcript file is written correctly.
@Suite("TranscribePipeline")
struct TranscribePipelineTests {
  private let now = Instant(secondsSinceEpoch: 2_000_000_000)
  private let asrSampleRate = 16000

  private func makeTempDirectory(_ label: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "TranscribePipelineTests-\(label)-\(UUID().uuidString)")
  }

  /// Writes `meta.toml` (via ``SourceMetaStore``, matching what ``EarsDaemon``
  /// now writes at construction -- see `EarsDaemonTests`' own coverage of
  /// that), a real encoded `asr/` chunk file (a tone, via the same
  /// `AVFoundationChunkFileWriter` `earsd` uses), and a real `index.jsonl`
  /// with one `chunk` event and one `vad` speech span, for `sourceID` under
  /// `dataRoot` -- everything ``SegmentedAudioReader`` (the real composition
  /// root `TranscribePipeline` reads through) needs to resolve and decode a
  /// real source end to end.
  @discardableResult
  private func writeFixtureSource(
    sourceID: SourceID,
    dataRoot: URL,
    chunkStart: Instant,
    chunkDuration: Double,
    vadSpeechStart: Instant,
    vadSpeechEnd: Instant
  ) async throws -> URL {
    try SourceMetaStore.write(
      SourceDescriptor(
        schema: 1, id: sourceID, sourceClass: sourceID.sourceClass ?? .mic,
        label: sourceID.rawValue, nativeSampleRate: 48000, asrSampleRate: asrSampleRate,
        storeNative: true, channels: 1, codec: "aac", bitrate: 64000,
        created: chunkStart),
      dataRoot: dataRoot)

    let sampleCount = Int(chunkDuration * Double(asrSampleRate))
    let samples = (0..<sampleCount).map { index in
      Float(sin(2.0 * Double.pi * 440.0 * Double(index) / Double(asrSampleRate)) * 0.5)
    }
    let asrDirectory = DataStoreLayout.asrDirectory(dataRoot: dataRoot, sourceID: sourceID)
    try FileManager.default.createDirectory(at: asrDirectory, withIntermediateDirectories: true)
    let filename = FilenameTimestampCodec.string(for: chunkStart) + ".m4a"
    let chunkURL = asrDirectory.appendingPathComponent(filename)
    let settings = ChunkAudioSettings(codec: "aac", sampleRate: asrSampleRate, bitrate: 64000)
    let writer = try AVFoundationChunkFileWriter(url: chunkURL, settings: settings)
    try writer.write(samples: samples)
    try writer.finish()

    let indexAppender = IndexAppender(
      fileURL: DataStoreLayout.structuralIndexFile(dataRoot: dataRoot, sourceID: sourceID))
    try await indexAppender.append(
      .chunk(
        start: chunkStart, end: chunkStart.advanced(by: chunkDuration), file: "asr/\(filename)",
        frames: sampleCount))
    try await VADSegmentWriter(
      directory: DataStoreLayout.vadDirectory(dataRoot: dataRoot, sourceID: sourceID)
    ).append(state: .speech, start: vadSpeechStart, end: vadSpeechEnd)

    return chunkURL
  }

  private func outputText(at url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
  }

  @Test("no --source is a precise, non-zero error")
  func noSourceIsError() async throws {
    let dataRoot = makeTempDirectory("no-source")
    let outputRoot = makeTempDirectory("no-source-output")

    let exitCode = await TranscribePipeline.run(
      inputs: .init(last: "20s", sourceIDs: [], out: nil),
      dataRoot: dataRoot,
      outputRoot: outputRoot,
      backendName: "fluidaudio",
      dependencies: .init(
        clock: ManualClock(now),
        transcriberFactory: { NullTranscriber() },
        loadOptions: LoadOptions(),
        log: { _ in },
        writeStderr: { _ in }
      )
    )

    #expect(exitCode == 1)
  }

  @Test("an unknown source is a precise, non-zero error, and never invokes the transcriber")
  func unknownSourceIsError() async throws {
    let dataRoot = makeTempDirectory("unknown-source")
    let outputRoot = makeTempDirectory("unknown-source-output")

    let exitCode = await TranscribePipeline.run(
      inputs: .init(last: "20s", sourceIDs: ["mic"], out: nil),
      dataRoot: dataRoot,
      outputRoot: outputRoot,
      backendName: "fluidaudio",
      dependencies: .init(
        clock: ManualClock(now),
        transcriberFactory: {
          Issue.record("transcriber should never be constructed for an unknown source")
          return NullTranscriber()
        },
        loadOptions: LoadOptions(),
        log: { _ in },
        writeStderr: { _ in }
      )
    )

    #expect(exitCode == 1)
  }

  @Test("an empty --last range is a precise, non-zero error")
  func emptyRangeIsError() async throws {
    let dataRoot = makeTempDirectory("empty-range")
    let outputRoot = makeTempDirectory("empty-range-output")
    try await writeFixtureSource(
      sourceID: "mic", dataRoot: dataRoot,
      chunkStart: now.advanced(by: -20), chunkDuration: 20,
      vadSpeechStart: now.advanced(by: -15), vadSpeechEnd: now.advanced(by: -5))

    let exitCode = await TranscribePipeline.run(
      inputs: .init(last: "0s", sourceIDs: ["mic"], out: nil),
      dataRoot: dataRoot,
      outputRoot: outputRoot,
      backendName: "fluidaudio",
      dependencies: .init(
        clock: ManualClock(now),
        transcriberFactory: { NullTranscriber() },
        loadOptions: LoadOptions(),
        log: { _ in },
        writeStderr: { _ in }
      )
    )

    #expect(exitCode == 1)
  }

  @Test("a single source's speech window is read, transcribed, and written to disk")
  func singleSourceEndToEnd() async throws {
    let dataRoot = makeTempDirectory("single-source")
    let outputRoot = makeTempDirectory("single-source-output")
    try await writeFixtureSource(
      sourceID: "mic", dataRoot: dataRoot,
      chunkStart: now.advanced(by: -20), chunkDuration: 20,
      vadSpeechStart: now.advanced(by: -15), vadSpeechEnd: now.advanced(by: -5))

    let scripted = ScriptedTranscriber(results: [
      [Segment(start: 0, end: 2, text: "hello world")]
    ])

    let exitCode = await TranscribePipeline.run(
      inputs: .init(last: "20s", sourceIDs: ["mic"], out: nil),
      dataRoot: dataRoot,
      outputRoot: outputRoot,
      backendName: "fluidaudio",
      dependencies: .init(
        clock: ManualClock(now),
        transcriberFactory: { scripted },
        loadOptions: LoadOptions(),
        log: { _ in },
        writeStderr: { line in Issue.record("unexpected stderr: \(line)") }
      )
    )

    #expect(exitCode == 0)
    #expect(scripted.recordedCalls.count == 1)

    // Default segmentation (0.2s pre-roll, 0.5s merge gap) turns the single
    // [-15, -5) speech span into one ~9.8s window. The exact decoded
    // sample count is not bit-precise against the nominal PCM duration --
    // AAC's real container/priming behavior can shift a decoded frame
    // range by up to a few hundred milliseconds even for a sub-range read
    // well inside a chunk (see AVFoundationChunkFileReaderTests' own
    // tolerance for the same reason) -- so this only checks the ballpark,
    // proving real audio actually got read and fed to the transcriber, not
    // that the codec round-trip is sample-exact (SegmentedAudioReaderTests'
    // fake-reader tests already cover the frame-selection math exactly).
    let fedAudio = scripted.recordedCalls[0].audio
    #expect(fedAudio.sampleRate == 16000)
    #expect(fedAudio.duration > 8 && fedAudio.duration < 10.5)

    let paths = OutputPathResolution.resolve(
      outputRoot: outputRoot, requestedStart: now.advanced(by: -20), sourceIDs: ["mic"],
      explicitOut: nil)
    let markdown = try outputText(at: paths.markdown)
    #expect(markdown.contains("hello world"))
    #expect(markdown.contains("You"))
    #expect(markdown.contains("kind: transcript"))
    #expect(markdown.contains("sources: [mic]"))

    let json = try outputText(at: paths.sidecar)
    let sidecar = try #require(
      try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    let segments = try #require(sidecar["segments"] as? [[String: Any]])
    #expect(segments.count == 1)
    #expect(segments[0]["text"] as? String == "hello world")
    // The scripted segment's offsets (0...2, relative to its own slice) get
    // shifted by the slice's 4.7s offset from the requested range's start
    // (default SegmentationOptions.preRollSeconds is 0.3s on this base, so
    // the slice starts at -15.3, range starts at -20 => offset 4.7).
    let segmentStart = try #require(segments[0]["start"] as? Double)
    let segmentEnd = try #require(segments[0]["end"] as? Double)
    #expect(abs(segmentStart - 4.7) < 0.001)
    #expect(abs(segmentEnd - 6.7) < 0.001)
  }

  @Test(
    "--session resolves range/sources from a real session.toml fixture, with no --source needed")
  func sessionEndToEnd() async throws {
    let dataRoot = makeTempDirectory("session")
    let outputRoot = makeTempDirectory("session-output")
    // Sessions are materialized from meetings with slug = meeting id, and a
    // meeting's audio lives under its own directory — so the fixture audio
    // goes under meetings/<slug>/sources/mic/, where the pipeline reads it.
    try await writeFixtureSource(
      sourceID: "mic",
      dataRoot: DataStoreLayout.meetingDirectory(dataRoot: dataRoot, meetingID: "standup"),
      chunkStart: now.advanced(by: -20), chunkDuration: 20,
      vadSpeechStart: now.advanced(by: -15), vadSpeechEnd: now.advanced(by: -5))

    let descriptor = SessionDescriptor(
      schema: 1, id: "session-fixture_standup", slug: "standup", sources: ["mic"],
      start: now.advanced(by: -20), end: now, state: .closed, trigger: .manual)
    try SessionStore.write(descriptor, dataRoot: dataRoot)

    let scripted = ScriptedTranscriber(results: [
      [Segment(start: 0, end: 2, text: "session hello")]
    ])

    let exitCode = await TranscribePipeline.run(
      inputs: .init(session: "session-fixture_standup", sourceIDs: [], out: nil),
      dataRoot: dataRoot,
      outputRoot: outputRoot,
      backendName: "fluidaudio",
      dependencies: .init(
        clock: ManualClock(now),
        transcriberFactory: { scripted },
        loadOptions: LoadOptions(),
        log: { _ in },
        writeStderr: { line in Issue.record("unexpected stderr: \(line)") }
      )
    )

    #expect(exitCode == 0)
    #expect(scripted.recordedCalls.count == 1)

    // The session's real id/slug drive the output filename, not a
    // synthesized <timestamp>_<sources> stand-in.
    let expectedPaths = OutputPathResolution.resolve(
      outputRoot: outputRoot, requestedStart: now.advanced(by: -20), sourceIDs: ["mic"],
      explicitOut: nil, sessionSlug: "standup")
    let markdown = try outputText(at: expectedPaths.markdown)
    #expect(markdown.contains("session hello"))
    #expect(markdown.contains("session: session-fixture_standup"))
  }

  @Test(
    "--session with pre_roll_seconds widens the read range to include speech before the session's nominal start"
  )
  func sessionPreRollWidensRange() async throws {
    let dataRoot = makeTempDirectory("pre-roll")
    let outputRoot = makeTempDirectory("pre-roll-output")
    // A speech span well before the session's nominal start (-10), but
    // within a 16s pre-roll window (nominal start - 16 = -26).
    try await writeFixtureSource(
      sourceID: "mic",
      dataRoot: DataStoreLayout.meetingDirectory(dataRoot: dataRoot, meetingID: "standup"),
      chunkStart: now.advanced(by: -30), chunkDuration: 30,
      vadSpeechStart: now.advanced(by: -24), vadSpeechEnd: now.advanced(by: -20))

    let descriptor = SessionDescriptor(
      schema: 1, id: "session-preroll_standup", slug: "standup", sources: ["mic"],
      start: now.advanced(by: -10), end: now, state: .closed, trigger: .manual,
      preRollSeconds: 16)
    try SessionStore.write(descriptor, dataRoot: dataRoot)

    let scripted = ScriptedTranscriber(results: [
      [Segment(start: 0, end: 2, text: "pre-roll speech")]
    ])

    let exitCode = await TranscribePipeline.run(
      inputs: .init(session: "session-preroll_standup", sourceIDs: [], out: nil),
      dataRoot: dataRoot,
      outputRoot: outputRoot,
      backendName: "fluidaudio",
      dependencies: .init(
        clock: ManualClock(now),
        transcriberFactory: { scripted },
        loadOptions: LoadOptions(),
        log: { _ in },
        writeStderr: { line in Issue.record("unexpected stderr: \(line)") }
      )
    )

    #expect(exitCode == 0)
    // Without the pre-roll widening, this speech span (entirely before the
    // session's nominal start) would never be read at all -- proving the
    // widened range is what made this call happen.
    #expect(scripted.recordedCalls.count == 1)
    #expect(scripted.recordedCalls[0].audio.duration > 0)

    let markdown = try outputText(
      at: OutputPathResolution.resolve(
        outputRoot: outputRoot, requestedStart: now.advanced(by: -26), sourceIDs: ["mic"],
        explicitOut: nil, sessionSlug: "standup"
      ).markdown)
    #expect(markdown.contains("pre-roll speech"))
  }

  @Test("--meeting reads the meeting's audio from its own directory and writes a transcript")
  func meetingEndToEnd() async throws {
    let dataRoot = makeTempDirectory("meeting")
    let outputRoot = makeTempDirectory("meeting-output")
    let meetingID = "fixture-meeting"

    // meeting.toml lives under the global data root; the audio lives under
    // the meeting's own directory — the pipeline must read each from its
    // respective root.
    let meeting = Meeting(
      id: meetingID,
      title: "call",
      state: .ended,
      started: now.advanced(by: -20),
      ended: now,
      intervals: [MeetingInterval(start: now.advanced(by: -20), end: now)],
      sources: ["mic"])
    try MeetingStore.write(meeting, dataRoot: dataRoot)

    try await writeFixtureSource(
      sourceID: "mic",
      dataRoot: DataStoreLayout.meetingDirectory(dataRoot: dataRoot, meetingID: meetingID),
      chunkStart: now.advanced(by: -20), chunkDuration: 20,
      vadSpeechStart: now.advanced(by: -15), vadSpeechEnd: now.advanced(by: -5))

    let scripted = ScriptedTranscriber(results: [
      [Segment(start: 0, end: 2, text: "meeting hello")]
    ])

    let exitCode = await TranscribePipeline.run(
      inputs: .init(meeting: meetingID, sourceIDs: [], out: nil),
      dataRoot: dataRoot,
      outputRoot: outputRoot,
      backendName: "fluidaudio",
      dependencies: .init(
        clock: ManualClock(now),
        transcriberFactory: { scripted },
        loadOptions: LoadOptions(),
        log: { _ in },
        writeStderr: { line in Issue.record("unexpected stderr: \(line)") }
      )
    )

    #expect(exitCode == 0)
    #expect(scripted.recordedCalls.count == 1)

    let paths = OutputPathResolution.resolve(
      outputRoot: outputRoot, requestedStart: now.advanced(by: -20), sourceIDs: ["mic"],
      explicitOut: nil, sessionSlug: meetingID)
    let markdown = try outputText(at: paths.markdown)
    #expect(markdown.contains("meeting hello"))
    #expect(markdown.contains("meeting: \(meetingID)"))
  }

  @Test(
    "--meeting reads per-meeting chunks for a source that has them and falls back to the ring for one that doesn't"
  )
  func meetingPrefersPerMeetingAndFallsBackToRing() async throws {
    let dataRoot = makeTempDirectory("meeting-mixed")
    let outputRoot = makeTempDirectory("meeting-mixed-output")
    let meetingID = "mixed-meeting"

    let meeting = Meeting(
      id: meetingID,
      title: "call",
      state: .ended,
      started: now.advanced(by: -20),
      ended: now,
      intervals: [MeetingInterval(start: now.advanced(by: -20), end: now)],
      sources: ["mic", "browser:meet:speaker-1"])
    try MeetingStore.write(meeting, dataRoot: dataRoot)

    // mic has NO per-meeting dir — only the ring holds it (the issue's mic
    // case). The browser source is the authoritative per-meeting copy and has
    // no ring dir at all.
    try await writeFixtureSource(
      sourceID: "mic", dataRoot: dataRoot,
      chunkStart: now.advanced(by: -20), chunkDuration: 20,
      vadSpeechStart: now.advanced(by: -8), vadSpeechEnd: now.advanced(by: -6))
    try await writeFixtureSource(
      sourceID: "browser:meet:speaker-1",
      dataRoot: DataStoreLayout.meetingDirectory(dataRoot: dataRoot, meetingID: meetingID),
      chunkStart: now.advanced(by: -20), chunkDuration: 20,
      vadSpeechStart: now.advanced(by: -15), vadSpeechEnd: now.advanced(by: -13))

    // Read order follows the meeting's source list: mic (ring) then browser
    // (per-meeting).
    let scripted = ScriptedTranscriber(results: [
      [Segment(start: 0, end: 1, text: "mic-from-ring")],
      [Segment(start: 0, end: 1, text: "browser-from-meeting")],
    ])

    let exitCode = await TranscribePipeline.run(
      inputs: .init(meeting: meetingID, sourceIDs: [], out: nil),
      dataRoot: dataRoot,
      outputRoot: outputRoot,
      backendName: "fluidaudio",
      dependencies: .init(
        clock: ManualClock(now),
        transcriberFactory: { scripted },
        loadOptions: LoadOptions(),
        log: { _ in },
        writeStderr: { line in Issue.record("unexpected stderr: \(line)") }
      )
    )

    #expect(exitCode == 0)
    #expect(scripted.recordedCalls.count == 2)

    let paths = OutputPathResolution.resolve(
      outputRoot: outputRoot, requestedStart: now.advanced(by: -20),
      sourceIDs: ["mic", "browser:meet:speaker-1"], explicitOut: nil, sessionSlug: meetingID)
    let markdown = try outputText(at: paths.markdown)
    #expect(markdown.contains("mic-from-ring"))
    #expect(markdown.contains("browser-from-meeting"))
    // The chosen lookup order is recorded in frontmatter, per issue #20.
    #expect(markdown.contains("audio_stores: [\"mic=ring\", \"browser:meet:speaker-1=meeting\"]"))

    // Frontmatter round-trips the per-source store record.
    let parsed = try TranscriptParser.parseFrontmatter(markdown)
    #expect(
      parsed.audioStores == [
        TranscriptAudioStore(source: "mic", store: "ring"),
        TranscriptAudioStore(source: "browser:meet:speaker-1", store: "meeting"),
      ])
  }

  @Test("--meeting with no audio in any store exits 0 and logs a per-source reason")
  func meetingEmptyLogsPerSourceReason() async throws {
    let dataRoot = makeTempDirectory("meeting-empty")
    let outputRoot = makeTempDirectory("meeting-empty-output")
    let meetingID = "empty-meeting"

    // meeting.toml exists, but neither the per-meeting dir nor the ring holds
    // either source's audio.
    let meeting = Meeting(
      id: meetingID,
      title: "call",
      state: .ended,
      started: now.advanced(by: -20),
      ended: now,
      intervals: [MeetingInterval(start: now.advanced(by: -20), end: now)],
      sources: ["mic", "browser:meet:speaker-2"])
    try MeetingStore.write(meeting, dataRoot: dataRoot)

    let logs = LogCollector()
    let exitCode = await TranscribePipeline.run(
      inputs: .init(meeting: meetingID, sourceIDs: [], out: nil),
      dataRoot: dataRoot,
      outputRoot: outputRoot,
      backendName: "fluidaudio",
      dependencies: .init(
        clock: ManualClock(now),
        transcriberFactory: { ScriptedTranscriber(results: []) },
        loadOptions: LoadOptions(),
        log: { logs.append($0) },
        writeStderr: { line in Issue.record("unexpected stderr: \(line)") }
      )
    )

    #expect(exitCode == 0)
    let lines = logs.snapshot()
    // Every source names why it was silent, and each store consulted is logged.
    #expect(lines.contains { $0.contains("run.empty: source=mic reason=store missing") })
    #expect(
      lines.contains {
        $0.contains("run.empty: source=browser:meet:speaker-2 reason=store missing")
      })
    #expect(lines.contains { $0.contains("source mic: consulted meeting store at") })
    #expect(lines.contains { $0.contains("source mic: consulted ring store at") })

    // An empty meeting still produces a (segment-less) transcript with the
    // per-source store record (`none`, since nothing was found).
    let paths = OutputPathResolution.resolve(
      outputRoot: outputRoot, requestedStart: now.advanced(by: -20),
      sourceIDs: ["mic", "browser:meet:speaker-2"], explicitOut: nil, sessionSlug: meetingID)
    let markdown = try outputText(at: paths.markdown)
    #expect(markdown.contains("audio_stores: [\"mic=none\", \"browser:meet:speaker-2=none\"]"))
  }

  @Test(
    "--meeting with one source that has data and one that has none transcribes the former, exits 0, and reports the missing source in the log and transcript metadata"
  )
  func meetingMissingOneSourceTranscribesRest() async throws {
    // The issue's exact shape: `meeting.toml` lists `mic` plus a browser
    // source, but `mic` was misrouted (issue #19) and has no data in either
    // store. The browser source's per-meeting audio is present. The run must
    // transcribe the browser source, exit 0 (never exit-1-with-no-message,
    // never a silent exit-0-empty), and name `mic` as missing in both the log
    // and the transcript's per-source `audio_stores` record (issue #21).
    let dataRoot = makeTempDirectory("meeting-partial")
    let outputRoot = makeTempDirectory("meeting-partial-output")
    let meetingID = "b7acc61f"

    let meeting = Meeting(
      id: meetingID,
      title: "call",
      state: .ended,
      started: now.advanced(by: -20),
      ended: now,
      intervals: [MeetingInterval(start: now.advanced(by: -20), end: now)],
      sources: ["mic", "browser:meet:speaker-1"])
    try MeetingStore.write(meeting, dataRoot: dataRoot)

    // Only the browser source has audio (its authoritative per-meeting copy);
    // `mic` has no directory in the per-meeting tree or the ring.
    try await writeFixtureSource(
      sourceID: "browser:meet:speaker-1",
      dataRoot: DataStoreLayout.meetingDirectory(dataRoot: dataRoot, meetingID: meetingID),
      chunkStart: now.advanced(by: -20), chunkDuration: 20,
      vadSpeechStart: now.advanced(by: -10), vadSpeechEnd: now.advanced(by: -8))

    let logs = LogCollector()
    let scripted = ScriptedTranscriber(results: [
      [Segment(start: 0, end: 2, text: "speaker one speaking")]
    ])

    let exitCode = await TranscribePipeline.run(
      inputs: .init(meeting: meetingID, sourceIDs: [], out: nil),
      dataRoot: dataRoot,
      outputRoot: outputRoot,
      backendName: "fluidaudio",
      dependencies: .init(
        clock: ManualClock(now),
        transcriberFactory: { scripted },
        loadOptions: LoadOptions(),
        log: { logs.append($0) },
        writeStderr: { line in Issue.record("unexpected stderr: \(line)") }
      )
    )

    // The remaining source transcribed and the run succeeded — not a failure.
    #expect(exitCode == 0)
    #expect(scripted.recordedCalls.count == 1)

    let lines = logs.snapshot()
    // The missing source is named, non-silently, with its no-data reason...
    #expect(lines.contains { $0.contains("meeting \(meetingID) source mic: no audio store found") })
    // The run produced segments, so it is not an empty run at all.
    #expect(!lines.contains { $0.contains("run.empty:") })
    // ...and the run summary's honest resolved/missing counts distinguish this
    // from silence (issue #21).
    #expect(lines.contains { $0.contains("sources_resolved=1 sources_missing=1") })

    let paths = OutputPathResolution.resolve(
      outputRoot: outputRoot, requestedStart: now.advanced(by: -20),
      sourceIDs: ["mic", "browser:meet:speaker-1"], explicitOut: nil, sessionSlug: meetingID)
    let markdown = try outputText(at: paths.markdown)
    // The transcript carries the transcribed text and, in metadata, the
    // per-source outcome: `mic` read from no store, the browser source from the
    // per-meeting copy.
    #expect(markdown.contains("speaker one speaking"))
    #expect(
      markdown.contains("audio_stores: [\"mic=none\", \"browser:meet:speaker-1=meeting\"]"))
  }

  @Test(
    "--meeting reads per-meeting chunks even when the ring also holds the source (per-meeting is authoritative)"
  )
  func meetingPrefersPerMeetingOverRing() async throws {
    let dataRoot = makeTempDirectory("meeting-both")
    let outputRoot = makeTempDirectory("meeting-both-output")
    let meetingID = "both-meeting"

    let meeting = Meeting(
      id: meetingID,
      title: "call",
      state: .ended,
      started: now.advanced(by: -20),
      ended: now,
      intervals: [MeetingInterval(start: now.advanced(by: -20), end: now)],
      sources: ["mic"])
    try MeetingStore.write(meeting, dataRoot: dataRoot)

    // Both stores hold mic; the per-meeting copy must win, so only one read
    // (of the per-meeting store) happens.
    try await writeFixtureSource(
      sourceID: "mic", dataRoot: dataRoot,
      chunkStart: now.advanced(by: -20), chunkDuration: 20,
      vadSpeechStart: now.advanced(by: -8), vadSpeechEnd: now.advanced(by: -6))
    try await writeFixtureSource(
      sourceID: "mic",
      dataRoot: DataStoreLayout.meetingDirectory(dataRoot: dataRoot, meetingID: meetingID),
      chunkStart: now.advanced(by: -20), chunkDuration: 20,
      vadSpeechStart: now.advanced(by: -15), vadSpeechEnd: now.advanced(by: -13))

    let scripted = ScriptedTranscriber(results: [
      [Segment(start: 0, end: 1, text: "hello")]
    ])

    let exitCode = await TranscribePipeline.run(
      inputs: .init(meeting: meetingID, sourceIDs: [], out: nil),
      dataRoot: dataRoot,
      outputRoot: outputRoot,
      backendName: "fluidaudio",
      dependencies: .init(
        clock: ManualClock(now),
        transcriberFactory: { scripted },
        loadOptions: LoadOptions(),
        log: { _ in },
        writeStderr: { line in Issue.record("unexpected stderr: \(line)") }
      )
    )

    #expect(exitCode == 0)
    // Only the chosen (per-meeting) store is read — never both.
    #expect(scripted.recordedCalls.count == 1)

    let paths = OutputPathResolution.resolve(
      outputRoot: outputRoot, requestedStart: now.advanced(by: -20), sourceIDs: ["mic"],
      explicitOut: nil, sessionSlug: meetingID)
    let markdown = try outputText(at: paths.markdown)
    #expect(markdown.contains("audio_stores: [\"mic=meeting\"]"))
  }

  @Test("segments from two sources are merged onto one shared timeline, ordered by time")
  func twoSourcesMergeByTime() async throws {
    let dataRoot = makeTempDirectory("two-sources")
    let outputRoot = makeTempDirectory("two-sources-output")

    // mic's speech span is chronologically *later* (closer to `now`) than
    // zoom's, so the merged transcript must reorder them by wall-clock
    // time rather than by source-list order (mic is listed first).
    try await writeFixtureSource(
      sourceID: "mic", dataRoot: dataRoot,
      chunkStart: now.advanced(by: -20), chunkDuration: 20,
      vadSpeechStart: now.advanced(by: -8), vadSpeechEnd: now.advanced(by: -6))
    try await writeFixtureSource(
      sourceID: "app:us.zoom.xos", dataRoot: dataRoot,
      chunkStart: now.advanced(by: -20), chunkDuration: 20,
      vadSpeechStart: now.advanced(by: -15), vadSpeechEnd: now.advanced(by: -13))

    // One Transcriber instance serves the whole run (it's constructed once
    // and reused across every source/slice, matching
    // docs/specs/model-interface.md's "stateless manager, caller owns
    // continuity" pattern) -- ScriptedTranscriber's results queue is
    // consumed in call order, so the first scripted result answers mic's
    // slice (mic is listed first) and the second answers zoom's. mic's
    // slice is scripted to return a segment placed *after* the zoom
    // source's segment in wall-clock time, so a naive "concatenate in
    // source order" (rather than a true merge-by-time) would get the order
    // wrong.
    let scripted = ScriptedTranscriber(results: [
      [Segment(start: 0, end: 1, text: "mic-later")],
      [Segment(start: 0, end: 1, text: "zoom-earlier")],
    ])

    let exitCode = await TranscribePipeline.run(
      inputs: .init(last: "20s", sourceIDs: ["mic", "app:us.zoom.xos"], out: nil),
      dataRoot: dataRoot,
      outputRoot: outputRoot,
      backendName: "fluidaudio",
      dependencies: .init(
        clock: ManualClock(now),
        transcriberFactory: { scripted },
        loadOptions: LoadOptions(),
        log: { _ in },
        writeStderr: { line in Issue.record("unexpected stderr: \(line)") }
      )
    )

    #expect(exitCode == 0)

    let paths = OutputPathResolution.resolve(
      outputRoot: outputRoot, requestedStart: now.advanced(by: -20),
      sourceIDs: ["mic", "app:us.zoom.xos"], explicitOut: nil)
    let markdown = try outputText(at: paths.markdown)

    let zoomRange = markdown.range(of: "zoom-earlier")
    let micRange = markdown.range(of: "mic-later")
    #expect(zoomRange != nil)
    #expect(micRange != nil)
    if let zoomRange, let micRange {
      #expect(zoomRange.lowerBound < micRange.lowerBound)
    }
    #expect(markdown.contains("app:us.zoom.xos"))
  }

  @Test("--out overrides the output path")
  func explicitOutOverridesPath() async throws {
    let dataRoot = makeTempDirectory("explicit-out")
    let outputRoot = makeTempDirectory("explicit-out-output")
    try await writeFixtureSource(
      sourceID: "mic", dataRoot: dataRoot,
      chunkStart: now.advanced(by: -20), chunkDuration: 20,
      vadSpeechStart: now.advanced(by: -15), vadSpeechEnd: now.advanced(by: -5))

    let customPath = makeTempDirectory("custom").appendingPathComponent("my-transcript.md").path
    let scripted = ScriptedTranscriber(results: [[]])

    let exitCode = await TranscribePipeline.run(
      inputs: .init(last: "20s", sourceIDs: ["mic"], out: customPath),
      dataRoot: dataRoot,
      outputRoot: outputRoot,
      backendName: "fluidaudio",
      dependencies: .init(
        clock: ManualClock(now),
        transcriberFactory: { scripted },
        loadOptions: LoadOptions(),
        log: { _ in },
        writeStderr: { line in Issue.record("unexpected stderr: \(line)") }
      )
    )

    #expect(exitCode == 0)
    #expect(FileManager.default.fileExists(atPath: customPath))
    let sidecarPath = (customPath as NSString).deletingPathExtension + ".json"
    #expect(FileManager.default.fileExists(atPath: sidecarPath))
  }

  @Test("the configured LoadOptions is passed through to the transcriber's load call")
  func loadOptionsPassedThrough() async throws {
    let dataRoot = makeTempDirectory("load-options")
    let outputRoot = makeTempDirectory("load-options-output")
    try await writeFixtureSource(
      sourceID: "mic", dataRoot: dataRoot,
      chunkStart: now.advanced(by: -20), chunkDuration: 20,
      vadSpeechStart: now.advanced(by: -15), vadSpeechEnd: now.advanced(by: -5))

    let recorder = LoadOptionsRecordingTranscriber()
    let requestedOptions = LoadOptions(modelIdentifier: "parakeet-tdt-v3", compute: .neuralEngine)

    let exitCode = await TranscribePipeline.run(
      inputs: .init(last: "20s", sourceIDs: ["mic"], out: nil),
      dataRoot: dataRoot,
      outputRoot: outputRoot,
      backendName: "fluidaudio",
      dependencies: .init(
        clock: ManualClock(now),
        transcriberFactory: { recorder },
        loadOptions: requestedOptions,
        log: { _ in },
        writeStderr: { line in Issue.record("unexpected stderr: \(line)") }
      )
    )

    #expect(exitCode == 0)
    #expect(recorder.loadedOptions == requestedOptions)
  }
}

/// Thread-safe collector for the pipeline's `@Sendable` `log` closure, so a
/// test can assert on the human-readable diagnostic lines it emits.
private final class LogCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var lines: [String] = []

  func append(_ line: String) {
    lock.lock()
    defer { lock.unlock() }
    lines.append(line)
  }

  func snapshot() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    return lines
  }
}

/// A minimal ``Transcriber`` that records the ``LoadOptions`` it was loaded
/// with, so ``TranscribePipelineTests`` can assert
/// ``TranscribePipeline/Dependencies``' `loadOptions` field actually reaches
/// `Transcriber.load(_:)`, independent of ``ScriptedTranscriber``'s own
/// unrelated segment-scripting job.
private final class LoadOptionsRecordingTranscriber: Transcriber, @unchecked Sendable {
  let info = ModelInfo(name: "recorder", version: "0", languages: ["en"])
  private(set) var loadedOptions: LoadOptions?

  func load(_ options: LoadOptions) throws {
    loadedOptions = options
  }

  func transcribe(_ audio: AudioBuffer, context: TranscribeContext) throws -> [Segment] { [] }
}

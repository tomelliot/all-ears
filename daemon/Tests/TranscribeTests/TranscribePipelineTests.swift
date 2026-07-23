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

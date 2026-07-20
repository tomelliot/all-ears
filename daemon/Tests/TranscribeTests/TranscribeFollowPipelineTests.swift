import EarsCore
import EarsCoreTestSupport
import EarsDataStore
import Foundation
import Synchronization
import Testing

@testable import transcribe

/// Tier-1 coverage of ``TranscribeFollowPipeline`` against a fixture ring
/// buffer that **grows during the test** — chunks and VAD spans appended to a
/// real `index.jsonl` while the pipeline runs, no daemon and no real model
/// (an injected ``ScriptedStreamingTranscriber`` plus a fake chunk reader, so
/// slice math is sample-exact with no codec round-trip nondeterminism).
///
/// The scripted step cadence is pinned so the *finalization* pass consumes
/// the scripted texts 1:1 per window: `stepSeconds` is set far above any
/// window length, so the fixed-cadence partial batcher never releases a step
/// and every `step(_:state:)` call is a window finalization decode.
@Suite("TranscribeFollowPipeline")
struct TranscribeFollowPipelineTests {
  private let now = Instant(secondsSinceEpoch: 2_000_000_000)
  private let asrRate = 16_000
  private let sourceID: SourceID = "mic"

  // MARK: - Fixture plumbing

  private struct FixtureMissing: Error {}

  private struct FakeChunkReader: ChunkFileReading {
    let frameCount: Int
    func read(frames range: Range<Int>) throws -> [Float] {
      Array(repeating: 0.1, count: range.count)
    }
  }

  /// One growing fixture source: `meta.toml` + a real `index.jsonl` on disk,
  /// with chunk audio served by a fake reader keyed on filename so decoded
  /// frame counts exactly match the nominal chunk durations.
  private final class Fixture: Sendable {
    let dataRoot: URL
    let outputRoot: URL
    let appender: IndexAppender
    private let chunkFrames = Mutex<[String: Int]>([:])

    init(label: String, sourceID: SourceID, asrRate: Int, created: Instant) throws {
      let base = FileManager.default.temporaryDirectory.appendingPathComponent(
        "FollowPipelineTests-\(label)-\(UUID().uuidString)")
      dataRoot = base.appendingPathComponent("data")
      outputRoot = base.appendingPathComponent("output")
      try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
      try SourceMetaStore.write(
        SourceDescriptor(
          schema: 1, id: sourceID, sourceClass: sourceID.sourceClass ?? .mic,
          label: sourceID.rawValue, nativeSampleRate: asrRate, asrSampleRate: asrRate,
          storeNative: false, channels: 1, codec: "aac", bitrate: 64_000, timeCapSeconds: 7_200,
          created: created),
        dataRoot: dataRoot)
      appender = IndexAppender(
        fileURL: DataStoreLayout.indexFile(dataRoot: dataRoot, sourceID: sourceID))
    }

    // `Mutex` is ~Copyable, so it can't be rebound to a local or captured
    // by value — the closure captures `self` (a Sendable class reference)
    // and borrows the property in place instead.
    var readerFactory: ChunkFileReaderFactory {
      { url in
        guard let frames = self.chunkFrames.withLock({ $0[url.lastPathComponent] }) else {
          throw FixtureMissing()
        }
        return FakeChunkReader(frameCount: frames)
      }
    }

    /// Appends one chunk event whose fake audio is exactly `duration` long.
    func appendChunk(start: Instant, duration: Double, asrRate: Int) async throws {
      let filename = FilenameTimestampCodec.string(for: start) + ".m4a"
      chunkFrames.withLock { $0[filename] = Int(duration * Double(asrRate)) }
      try await appender.append(
        .chunk(
          start: start, end: start.advanced(by: duration), file: "asr/\(filename)",
          frames: Int(duration * Double(asrRate))))
    }
  }

  /// Everything a test observes about one pipeline run, plus its controls.
  private final class Harness: Sendable {
    let stopFlag = Mutex<Bool>(false)
    let stdoutLines = Mutex<[String]>([])
    let published = Mutex<[EarsEvent]>([])
    let logs = Mutex<[String]>([])
    let stderrLines = Mutex<[String]>([])

    func dependencies(
      clock: any NowProviding,
      transcriber: any Transcriber,
      readerFactory: @escaping ChunkFileReaderFactory,
      maxWindowSeconds: Double = 60,
      finalizePadSeconds: Double = 0.25
    ) -> TranscribeFollowPipeline.Dependencies {
      // Closures capture `self` and borrow the ~Copyable Mutex properties
      // in place (they cannot be rebound or captured by value).
      return TranscribeFollowPipeline.Dependencies(
        clock: clock,
        transcriberFactory: { transcriber },
        loadOptions: LoadOptions(),
        readerFactory: readerFactory,
        // Far above any window length: the partial batcher never releases a
        // step, so scripted step texts map 1:1 onto finalization windows.
        stepSeconds: 1_000,
        maxWindowSeconds: maxWindowSeconds,
        minSilenceSeconds: 0.5,
        finalizePadSeconds: finalizePadSeconds,
        pollInterval: .milliseconds(1),
        sleep: { _ in await Task.yield() },
        isStopped: { self.stopFlag.withLock { $0 } },
        writeStdoutLine: { line in self.stdoutLines.withLock { $0.append(line) } },
        publishSegment: { event in self.published.withLock { $0.append(event) } },
        log: { line in self.logs.withLock { $0.append(line) } },
        writeStderr: { line in self.stderrLines.withLock { $0.append(line) } }
      )
    }

    /// Spins (cooperatively) until `condition` holds.
    func waitUntil(_ condition: @escaping @Sendable () -> Bool) async {
      while !condition() { await Task.yield() }
    }

    func waitForStart() async {
      await waitUntil { self.logs.withLock { $0.contains { $0.hasPrefix("following") } } }
    }

    func waitForStdout(count: Int) async {
      await waitUntil { self.stdoutLines.withLock { $0.count } >= count }
    }

    func stop() {
      stopFlag.withLock { $0 = true }
    }
  }

  private func launch(
    fixture: Fixture, dependencies: TranscribeFollowPipeline.Dependencies, json: Bool = false
  ) -> Task<Int32, Never> {
    let inputs = TranscribeFollowPipeline.Inputs(source: sourceID.rawValue, json: json, out: nil)
    let dataRoot = fixture.dataRoot
    let outputRoot = fixture.outputRoot
    return Task {
      await TranscribeFollowPipeline.run(
        inputs: inputs, dataRoot: dataRoot, outputRoot: outputRoot,
        backendName: "fluidaudio", dependencies: dependencies)
    }
  }

  // MARK: - Tests

  @Test("chunks appended mid-run are decoded at VAD pauses; all three sinks see each segment")
  func followsGrowingRingBuffer() async throws {
    let fixture = try Fixture(label: "grows", sourceID: sourceID, asrRate: asrRate, created: now)
    let harness = Harness()
    let scripted = ScriptedStreamingTranscriber(stepTexts: ["hello world", "second segment"])
    let dependencies = harness.dependencies(
      clock: ManualClock(now), transcriber: scripted, readerFactory: fixture.readerFactory)
    let run = launch(fixture: fixture, dependencies: dependencies)

    await harness.waitForStart()

    // First chunk lands after attach: speech then a >= 0.5 s silence whose
    // start is the natural-pause boundary at now+1.5.
    try await fixture.appendChunk(start: now, duration: 2, asrRate: asrRate)
    try await fixture.appender.append(
      .vad(state: .speech, start: now, end: now.advanced(by: 1.5)))
    try await fixture.appender.append(
      .vad(state: .silence, start: now.advanced(by: 1.5), end: now.advanced(by: 2.5)))
    await harness.waitForStdout(count: 1)

    // The ring buffer grows mid-run: a second chunk, another pause.
    try await fixture.appendChunk(start: now.advanced(by: 2), duration: 2, asrRate: asrRate)
    try await fixture.appender.append(
      .vad(state: .speech, start: now.advanced(by: 2.5), end: now.advanced(by: 3.5)))
    try await fixture.appender.append(
      .vad(state: .silence, start: now.advanced(by: 3.5), end: now.advanced(by: 4.2)))
    await harness.waitForStdout(count: 2)

    harness.stop()
    let exitCode = await run.value
    #expect(exitCode == 0)

    // stdout: append-only, one line per finalised segment, never retracted.
    let lines = harness.stdoutLines.withLock { $0 }
    #expect(lines.count == 2)
    #expect(lines[0].hasSuffix("You: hello world"))
    #expect(lines[1].hasSuffix("You: second segment"))

    // The finalization decodes saw exactly the sliced windows (plus the
    // trailing-silence pad): [0, 1.5) then [1.5, 3.5).
    let steps = scripted.recordedSteps
    #expect(steps.count == 2)
    #expect(steps[0].frameCount == Int(1.5 * Double(asrRate)) + Int(0.25 * Double(asrRate)))
    #expect(steps[1].frameCount == Int(2.0 * Double(asrRate)) + Int(0.25 * Double(asrRate)))

    // Live feed: one segment event per commit, same session id and speaker.
    let sessionID = OutputPathResolution.sessionIdentifier(
      requestedStart: now, sourceIDs: [sourceID])
    let events = harness.published.withLock { $0 }
    #expect(events.count == 2)
    guard case .segment(let segment) = events.first
    else {
      Issue.record("expected a segment event, got \(String(describing: events.first))")
      return
    }
    #expect(segment.session == sessionID)
    #expect(segment.speaker == "You")
    #expect(segment.start == 0)
    #expect(abs(segment.end - 1.5) < 0.001)
    #expect(segment.text == "hello world")

    // Transcript file: the same renderer/format batch mode writes, complete
    // and well-formed at exit.
    let paths = OutputPathResolution.resolve(
      outputRoot: fixture.outputRoot, requestedStart: now, sourceIDs: [sourceID], explicitOut: nil)
    let markdown = try String(contentsOf: paths.markdown, encoding: .utf8)
    #expect(markdown.hasPrefix("---\n"))
    #expect(markdown.contains("kind: transcript"))
    #expect(markdown.contains("session: \(sessionID)"))
    #expect(markdown.contains("sources: [mic]"))
    #expect(markdown.contains("hello world"))
    #expect(markdown.contains("second segment"))
    let hello = try #require(markdown.range(of: "hello world"))
    let second = try #require(markdown.range(of: "second segment"))
    #expect(hello.lowerBound < second.lowerBound)

    let sidecar = try String(contentsOf: paths.sidecar, encoding: .utf8)
    let json = try #require(
      try JSONSerialization.jsonObject(with: Data(sidecar.utf8)) as? [String: Any])
    let segments = try #require(json["segments"] as? [[String: Any]])
    #expect(segments.count == 2)
    #expect(segments[0]["text"] as? String == "hello world")
    #expect(segments[1]["text"] as? String == "second segment")
  }

  @Test("a cap-forced cut holds back the trailing partial token until a later window confirms it")
  func capForcedCutHoldsBackTrailingToken() async throws {
    let fixture = try Fixture(label: "cap", sourceID: sourceID, asrRate: asrRate, created: now)
    let harness = Harness()
    // No VAD events at all: every finalization is either the 2 s window cap
    // (unconfirmed — trailing token held back) or end-of-stream (confirmed).
    let scripted = ScriptedStreamingTranscriber(stepTexts: ["hello wor", "ld again", "done"])
    let dependencies = harness.dependencies(
      clock: ManualClock(now), transcriber: scripted, readerFactory: fixture.readerFactory,
      maxWindowSeconds: 2)
    let run = launch(fixture: fixture, dependencies: dependencies)

    await harness.waitForStart()
    try await fixture.appendChunk(start: now, duration: 5, asrRate: asrRate)
    await harness.waitForStdout(count: 2)
    harness.stop()
    #expect(await run.value == 0)

    let lines = harness.stdoutLines.withLock { $0 }
    #expect(lines.count == 3)
    // The first cap cut ended mid-token: "wor" must NOT appear in the first
    // emitted line (held back), and instead leads the second.
    #expect(lines[0].hasSuffix("You: hello"))
    #expect(lines[1].hasSuffix("You: wor ld"))
    // End of stream is a confirmed boundary: everything flushes.
    #expect(lines[2].hasSuffix("You: again done"))
  }

  @Test(
    "a pause-free run longer than the window cap is cut at the cap before its VAD boundary, so no finalization decode exceeds the model window"
  )
  func longRunToVadBoundaryIsCutAtCap() async throws {
    let fixture = try Fixture(label: "long-run", sourceID: sourceID, asrRate: asrRate, created: now)
    let harness = Harness()
    let scripted = ScriptedStreamingTranscriber(stepTexts: ["one two", "three four", "five"])
    let dependencies = harness.dependencies(
      clock: ManualClock(now), transcriber: scripted, readerFactory: fixture.readerFactory,
      maxWindowSeconds: 2)
    let run = launch(fixture: fixture, dependencies: dependencies)

    await harness.waitForStart()
    // One 5 s chunk lands at once (a ring-buffer chunk is far longer than
    // the cap), all speech, with the first natural pause only at 4.5 s.
    try await fixture.appendChunk(start: now, duration: 5, asrRate: asrRate)
    try await fixture.appender.append(
      .vad(state: .speech, start: now, end: now.advanced(by: 4.5)))
    try await fixture.appender.append(
      .vad(state: .silence, start: now.advanced(by: 4.5), end: now.advanced(by: 5.2)))
    await harness.waitForStdout(count: 3)
    harness.stop()
    #expect(await run.value == 0)

    // Decoded as [0,2) + [2,4) cap cuts, then [4,4.5) at the confirmed
    // pause — never one giant slice up to the 4.5 s boundary.
    let steps = scripted.recordedSteps
    #expect(steps.count == 3)
    let capFrames = Int(2.0 * Double(asrRate))
    #expect(steps.allSatisfy { $0.frameCount <= capFrames + Int(0.25 * Double(asrRate)) })
    #expect(steps[0].frameCount == capFrames)
    #expect(steps[1].frameCount == capFrames)
    // The confirmed-boundary slice carries the trailing-silence pad; the
    // cap cuts (mid-speech) deliberately do not.
    #expect(steps[2].frameCount == Int(0.5 * Double(asrRate)) + Int(0.25 * Double(asrRate)))

    let lines = harness.stdoutLines.withLock { $0 }
    #expect(lines.count == 3)
    #expect(lines[0].hasSuffix("You: one"))
    #expect(lines[1].hasSuffix("You: two three"))
    #expect(lines[2].hasSuffix("You: four five"))
  }

  @Test("a failed finalization decode falls back to the window's partial-pass text")
  func finalizationFailureFallsBackToPartialText() async throws {
    let fixture = try Fixture(label: "fallback", sourceID: sourceID, asrRate: asrRate, created: now)
    let harness = Harness()
    // Partial steps (0.5 s = 8000 frames) decode scripted texts; the larger
    // finalization decode throws, forcing the fallback commit path.
    let flaky = FlakyStreamingTranscriber(
      stepTexts: ["p1", "p2", "p3", "p4"], failsAboveFrameCount: 8000)
    var dependencies = harness.dependencies(
      clock: ManualClock(now), transcriber: flaky, readerFactory: fixture.readerFactory)
    dependencies.stepSeconds = 0.5
    let run = launch(fixture: fixture, dependencies: dependencies)

    await harness.waitForStart()
    try await fixture.appendChunk(start: now, duration: 2, asrRate: asrRate)
    try await fixture.appender.append(
      .vad(state: .speech, start: now, end: now.advanced(by: 1.5)))
    try await fixture.appender.append(
      .vad(state: .silence, start: now.advanced(by: 1.5), end: now.advanced(by: 2.2)))
    await harness.waitForStdout(count: 1)
    harness.stop()
    #expect(await run.value == 0)

    // The committed segment is the partial pass's accumulated text, and the
    // degradation was logged rather than silently swallowed or fatal.
    let lines = harness.stdoutLines.withLock { $0 }
    #expect(lines.count == 1)
    #expect(lines[0].hasSuffix("You: p1 p2 p3 p4"))
    #expect(
      harness.logs.withLock { $0 }.contains { $0.contains("finalization decode failed") })
  }

  @Test("a window fully covered by VAD silence is dropped without a decode")
  func silenceOnlyWindowSkipsDecode() async throws {
    let fixture = try Fixture(label: "silence", sourceID: sourceID, asrRate: asrRate, created: now)
    let harness = Harness()
    let scripted = ScriptedStreamingTranscriber(stepTexts: ["should never be consumed"])
    let dependencies = harness.dependencies(
      clock: ManualClock(now), transcriber: scripted, readerFactory: fixture.readerFactory)
    let run = launch(fixture: fixture, dependencies: dependencies)

    await harness.waitForStart()
    try await fixture.appendChunk(start: now, duration: 2, asrRate: asrRate)
    try await fixture.appender.append(
      .vad(state: .silence, start: now, end: now.advanced(by: 2.5)))
    // Wait until the silence boundary has been ingested and processed: the
    // boundary at its start is behind the window start, so the window only
    // closes at end-of-stream — and must skip the decode entirely.
    await harness.waitUntil { [fixture] in
      (try? String(
        contentsOf: DataStoreLayout.indexFile(
          dataRoot: fixture.dataRoot, sourceID: self.sourceID), encoding: .utf8))?
        .contains("silence") == true
    }
    harness.stop()
    #expect(await run.value == 0)

    #expect(scripted.recordedSteps.isEmpty)
    #expect(harness.stdoutLines.withLock { $0 }.isEmpty)
    #expect(harness.published.withLock { $0 }.isEmpty)
  }

  @Test("--json emits the live feed's exact segment-event wire shape")
  func jsonLinesMatchLiveFeedShape() async throws {
    let fixture = try Fixture(label: "json", sourceID: sourceID, asrRate: asrRate, created: now)
    let harness = Harness()
    let scripted = ScriptedStreamingTranscriber(stepTexts: ["structured output"])
    let dependencies = harness.dependencies(
      clock: ManualClock(now), transcriber: scripted, readerFactory: fixture.readerFactory)
    let run = launch(fixture: fixture, dependencies: dependencies, json: true)

    await harness.waitForStart()
    try await fixture.appendChunk(start: now, duration: 2, asrRate: asrRate)
    try await fixture.appender.append(
      .vad(state: .speech, start: now, end: now.advanced(by: 1.0)))
    try await fixture.appender.append(
      .vad(state: .silence, start: now.advanced(by: 1.0), end: now.advanced(by: 2.0)))
    await harness.waitForStdout(count: 1)
    harness.stop()
    #expect(await run.value == 0)

    let line = try #require(harness.stdoutLines.withLock { $0.first })
    // --json emits the live feed's exact wire shape: the v2 EventFrame.
    let decoded = try JSONDecoder().decode(EventFrame.self, from: Data(line.utf8))
    guard case .segment(let segment) = decoded.event else {
      Issue.record("expected a segment event line, got \(decoded)")
      return
    }
    #expect(segment.speaker == "You")
    #expect(segment.text == "structured output")
  }

  @Test("an unknown source is a precise, non-zero error")
  func unknownSourceFailsFast() async throws {
    let fixture = try Fixture(label: "unknown", sourceID: sourceID, asrRate: asrRate, created: now)
    let harness = Harness()
    let dependencies = harness.dependencies(
      clock: ManualClock(now), transcriber: NullTranscriber(),
      readerFactory: fixture.readerFactory)

    let exitCode = await TranscribeFollowPipeline.run(
      inputs: TranscribeFollowPipeline.Inputs(source: "app:no.such.app", json: false, out: nil),
      dataRoot: fixture.dataRoot, outputRoot: fixture.outputRoot, backendName: "fluidaudio",
      dependencies: dependencies)

    #expect(exitCode == 1)
    #expect(
      harness.stderrLines.withLock { $0 }.contains { $0.contains("app:no.such.app") })
  }

  @Test("a backend without streaming support is a precise, non-zero error")
  func nonStreamingBackendFailsFast() async throws {
    let fixture = try Fixture(
      label: "no-streaming", sourceID: sourceID, asrRate: asrRate, created: now)
    let harness = Harness()
    let dependencies = harness.dependencies(
      clock: ManualClock(now), transcriber: NullTranscriber(),
      readerFactory: fixture.readerFactory)

    let exitCode = await TranscribeFollowPipeline.run(
      inputs: TranscribeFollowPipeline.Inputs(source: sourceID.rawValue, json: false, out: nil),
      dataRoot: fixture.dataRoot, outputRoot: fixture.outputRoot, backendName: "fluidaudio",
      dependencies: dependencies)

    #expect(exitCode == 1)
    #expect(
      harness.stderrLines.withLock { $0 }.contains { $0.contains("StreamingTranscriber") })
  }
}

/// A ``StreamingTranscriber`` whose small (partial-cadence) steps succeed
/// with scripted texts while any larger (finalization) decode throws —
/// drives ``TranscribeFollowPipeline``'s fallback-to-partial-text path.
private final class FlakyStreamingTranscriber: StreamingTranscriber {
  struct DecodeFailure: Error {}

  let info = ModelInfo(
    name: "flaky-streaming", version: "0", languages: ["en"], supportsStreaming: true)

  private let failsAboveFrameCount: Int
  private let stepTexts: Mutex<[String]>

  init(stepTexts: [String], failsAboveFrameCount: Int) {
    self.stepTexts = Mutex(stepTexts)
    self.failsAboveFrameCount = failsAboveFrameCount
  }

  func load(_ options: LoadOptions) throws {}

  func transcribe(_ audio: AudioBuffer, context: TranscribeContext) throws -> [Segment] { [] }

  func step(_ frames: AudioBuffer, state: inout DecoderState) throws -> [Segment] {
    guard frames.frameCount <= failsAboveFrameCount else { throw DecodeFailure() }
    state.framesConsumed += frames.frameCount
    let text = stepTexts.withLock { texts -> String in
      guard !texts.isEmpty else { return "" }
      return texts.removeFirst()
    }
    guard !text.isEmpty else { return [] }
    return [Segment(start: 0, end: frames.duration, text: text)]
  }
}

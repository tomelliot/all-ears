import EarsCaptureKit
import EarsCore
import EarsCoreTestSupport
import EarsDataStore
import EarsLogging
import Foundation
import Synchronization
import Testing

@testable import EarsDaemonKit

/// Tier-1 integration tests for ``CaptureActor``: a scripted
/// ``SyntheticCaptureBackend`` (no hardware/TCC) drives real
/// ``ChunkEncoder`` / ``IndexAppender`` / ``EnergyVAD`` instances writing to a
/// real temp directory, matching how `EarsDataStore`'s own tests exercise the
/// on-disk path. A ``ManualClock`` supplies every instant, so no test path
/// reads the wall clock.
@Suite("CaptureActor")
struct CaptureActorTests {
  private let nativeRate = 48_000
  private let asrRate = 16_000
  private let startEpoch = 1_000.0

  private func makeDataRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "CaptureActorTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func makeDescriptor(timeCapSeconds: Int = 7_200) -> SourceDescriptor {
    SourceDescriptor(
      schema: 1,
      id: "mic",
      sourceClass: .mic,
      label: "Microphone",
      nativeSampleRate: nativeRate,
      asrSampleRate: asrRate,
      storeNative: true,
      channels: 1,
      codec: "aac",
      bitrate: 64_000,
      timeCapSeconds: timeCapSeconds,
      created: Instant(secondsSinceEpoch: startEpoch)
    )
  }

  /// A mono buffer of `seconds` at `value` (0.5 lands well above the VAD's
  /// 0.02 energy threshold, so a full-value buffer classifies as speech). The
  /// stamp defaults to the source's native rate; pass `sampleRate:` to model a
  /// device delivering a *different* rate than the source is configured for —
  /// the production bug this fix guards against. Sample count derives from the
  /// stamped rate so `duration` stays honest.
  private func makeBuffer(
    seconds: Double, value: Float = 0.5, sampleRate: Int? = nil
  ) -> AudioBuffer {
    let rate = sampleRate ?? nativeRate
    return AudioBuffer(
      samples: [Float](repeating: value, count: Int(seconds * Double(rate))),
      sampleRate: rate)
  }

  private func makeActor(
    dataRoot: URL,
    clock: ManualClock,
    buffers: [AudioBuffer],
    chunkSeconds: Double = 1.0,
    timeCapSeconds: Int = 7_200,
    backend: (any CaptureBackend)? = nil,
    eventSink: EventSink? = nil,
    logSink: any LogRecordSink = NoOpLogRecordSink(),
    encoderNativeRate: Int? = nil
  ) throws -> CaptureActor {
    let descriptor = makeDescriptor(timeCapSeconds: timeCapSeconds)
    let indexAppender = IndexAppender(
      fileURL: DataStoreLayout.structuralIndexFile(dataRoot: dataRoot, sourceID: descriptor.id))
    let vadWriter = VADSegmentWriter(
      directory: DataStoreLayout.vadDirectory(dataRoot: dataRoot, sourceID: descriptor.id))
    let encoder = try ChunkEncoder(
      sourceID: descriptor.id,
      dataRoot: dataRoot,
      codec: descriptor.codec,
      bitrate: descriptor.bitrate,
      nativeSampleRate: encoderNativeRate ?? nativeRate,
      asrSampleRate: asrRate,
      storeNative: descriptor.storeNative,
      chunkSeconds: chunkSeconds,
      startInstant: clock.now(),
      indexAppender: indexAppender
    )
    return CaptureActor(
      descriptor: descriptor,
      dataRoot: dataRoot,
      backend: backend ?? SyntheticCaptureBackend(source: descriptor.id, buffers: buffers),
      encoder: encoder,
      indexAppender: indexAppender,
      vadWriter: vadWriter,
      vad: EnergyVAD(),
      clock: clock,
      eventSink: eventSink,
      logSink: logSink
    )
  }

  /// Merges the split logs — structural `chunks.jsonl` plus every VAD segment —
  /// back into one event list, so assertions can look for chunk/gap/evict *and*
  /// vad events exactly as they did against the old single index.
  private func indexEvents(dataRoot: URL) throws -> [IndexEvent] {
    var events: [IndexEvent] = []
    let structuralURL = DataStoreLayout.structuralIndexFile(dataRoot: dataRoot, sourceID: "mic")
    if FileManager.default.fileExists(atPath: structuralURL.path) {
      let parsed = IndexLog.parse(try String(contentsOf: structuralURL, encoding: .utf8))
      #expect(parsed.malformedLines.isEmpty)
      events.append(contentsOf: parsed.events)
    }
    for segment in VADSegmentStore.segmentURLs(
      directory: DataStoreLayout.vadDirectory(dataRoot: dataRoot, sourceID: "mic"))
    {
      let parsed = IndexLog.parse(try String(contentsOf: segment.url, encoding: .utf8))
      #expect(parsed.malformedLines.isEmpty)
      events.append(contentsOf: parsed.events)
    }
    return events.sorted { $0.start < $1.start }
  }

  private func chunkEvents(dataRoot: URL) throws -> [IndexEvent] {
    try indexEvents(dataRoot: dataRoot).filter {
      if case .chunk = $0 { return true } else { return false }
    }
  }

  // MARK: - Sample-rate normalization (the production bug)

  @Test("buffers stamped at a different rate than the source are normalized, not dropped")
  func normalizesOffRateBuffers() async throws {
    // The live incident: the input device switched to 16 kHz while the source
    // is configured native 48 kHz. Before the fix the encoder rejected every
    // buffer and 100% of audio was silently discarded. Now the actor resamples
    // to 48 kHz first, so chunks and VAD index entries still land.
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: startEpoch))
    let actor = try makeActor(
      dataRoot: dataRoot, clock: clock,
      buffers: [
        makeBuffer(seconds: 0.5, sampleRate: 16_000),
        makeBuffer(seconds: 0.5, sampleRate: 16_000),
      ],
      chunkSeconds: 1.0)

    try await actor.start()
    await actor.drainForTesting()
    // Flush the pending chunk: resampling rounding can leave the two half-second
    // buffers a hair under the 1.0s rollover threshold, so finalize explicitly
    // (the real stop/flush path) rather than depending on exact-duration rollover.
    await actor.stop()

    let events = try indexEvents(dataRoot: dataRoot)
    let chunks = events.compactMap { event -> (Instant, Instant, String, Int)? in
      if case .chunk(let s, let e, let f, let frames) = event { return (s, e, f, frames) }
      return nil
    }
    let vads = events.filter { if case .vad = $0 { return true } else { return false } }
    #expect(chunks.count == 1)
    #expect(!vads.isEmpty)

    let chunk = try #require(chunks.first)
    // Frames are counted in the native 48 kHz domain the encoder writes: the two
    // 16 kHz buffers hold 16 000 samples between them, but resampled to 48 kHz
    // they persist well over 24 000 — proof normalization ran (unnormalized, the
    // encoder's rate backstop would have rejected them and produced no chunk at
    // all). A one-time resampler warmup trims the head, so this is a floor, not
    // an exact count.
    #expect(chunk.3 > nativeRate / 2)

    // Real files landed in both the native `chunks/` and derived `asr/` dirs.
    let chunkURL = DataStoreLayout.sourceDirectory(dataRoot: dataRoot, sourceID: "mic")
      .appendingPathComponent(chunk.2)
    #expect(FileManager.default.fileExists(atPath: chunkURL.path))
    let asrEntries = try FileManager.default.contentsOfDirectory(
      at: DataStoreLayout.asrDirectory(dataRoot: dataRoot, sourceID: "mic"),
      includingPropertiesForKeys: nil)
    #expect(!asrEntries.isEmpty)
  }

  @Test("a mid-stream device rate flip still produces one contiguous chunk")
  func midStreamRateFlipStaysContiguous() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: startEpoch))
    // 0.5s at the native 48k, then 0.5s after the device drops to 16k. Both
    // normalize to 48k, so the two half-seconds still roll into one 1.0s chunk.
    let actor = try makeActor(
      dataRoot: dataRoot, clock: clock,
      buffers: [
        makeBuffer(seconds: 0.5),
        makeBuffer(seconds: 0.5, sampleRate: 16_000),
      ],
      chunkSeconds: 1.0)

    try await actor.start()
    await actor.drainForTesting()
    await actor.stop()  // finalize the pending chunk (see normalizesOffRateBuffers)

    let events = try indexEvents(dataRoot: dataRoot)
    let chunks = events.compactMap { event -> (Instant, Instant)? in
      if case .chunk(let s, let e, _, _) = event { return (s, e) }
      return nil
    }
    #expect(chunks.count == 1)
    let chunk = try #require(chunks.first)
    let chunkStart = chunk.0
    let chunkEnd = chunk.1
    #expect(chunkStart == Instant(secondsSinceEpoch: startEpoch))

    // The whole point: VAD coverage runs contiguously across the rate flip. Both
    // fully-voiced half-seconds normalize to 48k on one timeline, so the spans
    // start at the chunk start, run to its end, and leave no gap where the rate
    // changed. (Exact end is warmup-dependent, so it's tied to the chunk's own
    // bounds, not a nominal 1.0s.)
    let vads = events.compactMap { event -> (Instant, Instant)? in
      if case .vad(_, let s, let e) = event { return (s, e) }
      return nil
    }
    .sorted { $0.0 < $1.0 }
    #expect(!vads.isEmpty)
    let earliest = try #require(vads.first).0
    let latest = try #require(vads.map(\.1).max())
    #expect(abs(earliest.interval(since: chunkStart)) < 0.01)
    #expect(abs(latest.interval(since: chunkEnd)) < 0.01)
    for (prev, next) in zip(vads, vads.dropFirst()) {
      #expect(next.0 <= prev.1.advanced(by: 0.01))  // no gap between consecutive spans
    }
  }

  @Test("a device rate flip emits a capture.input_rate_changed notice")
  func logsInputRateChanged() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: startEpoch))
    let logger = RecordingLogRecordSink()
    let actor = try makeActor(
      dataRoot: dataRoot, clock: clock,
      buffers: [
        makeBuffer(seconds: 0.5),
        makeBuffer(seconds: 0.5, sampleRate: 16_000),
      ],
      chunkSeconds: 30, logSink: logger)

    try await actor.start()
    await actor.drainForTesting()

    // The flip from 48k to 16k is announced (the first buffer also emits one
    // establishing the initial rate; the flip is the record with to == 16000).
    let changes = logger.recorded.filter { $0.event == "capture.input_rate_changed" }
    let flip = changes.first { record in
      record.fields.contains(LogField("to", .int(16_000)))
    }
    let flipRecord = try #require(flip)
    #expect(flipRecord.level == .notice)
    #expect(flipRecord.fields.contains(LogField("from", .int(48_000))))
    #expect(flipRecord.fields.contains(LogField("target", .int(nativeRate))))
    #expect(flipRecord.fields.contains(LogField("source", .string("mic"))))
  }

  @Test("an encode failure is logged loudly and the consume loop survives it")
  func logsEncodeFailureAndSurvives() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: startEpoch))
    let logger = RecordingLogRecordSink()
    // Encoder built at 44.1k while the descriptor/normalizer target 48k: every
    // normalized (48k) buffer trips the encoder's sample-rate backstop. The old
    // empty `catch {}` swallowed this silently; now it must be logged, and the
    // loop must drain every buffer regardless.
    let actor = try makeActor(
      dataRoot: dataRoot, clock: clock,
      buffers: [makeBuffer(seconds: 0.5), makeBuffer(seconds: 0.5)],
      chunkSeconds: 1.0, logSink: logger, encoderNativeRate: 44_100)

    try await actor.start()
    await actor.drainForTesting()

    let failures = logger.recorded.filter { $0.event == "capture.encode_failed" }
    let first = try #require(failures.first)
    #expect(first.level == .error)
    #expect(first.fields.contains(LogField("source", .string("mic"))))
    #expect(first.fields.contains(LogField("count", .int(1))))
    // Loop survived to completion: the actor is still capturing, not crashed.
    #expect(await actor.status().state == .capturing)
    await actor.stop()
  }

  @Test("start() drains synthetic audio into chunk files and index entries")
  func startProducesChunksAndIndex() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: startEpoch))
    let actor = try makeActor(
      dataRoot: dataRoot, clock: clock,
      buffers: [makeBuffer(seconds: 0.5), makeBuffer(seconds: 0.5)], chunkSeconds: 1.0)

    try await actor.start()
    await actor.drainForTesting()

    let events = try indexEvents(dataRoot: dataRoot)
    let chunks = events.filter { if case .chunk = $0 { return true } else { return false } }
    let vads = events.filter { if case .vad = $0 { return true } else { return false } }
    #expect(chunks.count == 1)
    #expect(!vads.isEmpty)

    guard case .chunk(let start, let end, let file, _) = chunks[0] else {
      Issue.record("expected a chunk event")
      return
    }
    #expect(start == Instant(secondsSinceEpoch: startEpoch))
    #expect(abs(end.interval(since: start.advanced(by: 1.0))) < 0.001)

    let chunkURL = DataStoreLayout.sourceDirectory(dataRoot: dataRoot, sourceID: "mic")
      .appendingPathComponent(file)
    #expect(FileManager.default.fileExists(atPath: chunkURL.path))
  }

  @Test("vad events carry wall-clock instants derived from the buffer timeline")
  func vadEventsAreWallClock() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: startEpoch))
    let actor = try makeActor(
      dataRoot: dataRoot, clock: clock, buffers: [makeBuffer(seconds: 0.5)], chunkSeconds: 30)

    try await actor.start()
    await actor.drainForTesting()

    let vads = try indexEvents(dataRoot: dataRoot).compactMap { event -> (Instant, Instant)? in
      if case .vad(_, let start, let end) = event { return (start, end) }
      return nil
    }
    let first = try #require(vads.first)
    // The single full-value buffer starts at the encoder's anchor instant and
    // spans no more than its 0.5s duration (VAD offsets are buffer-relative,
    // translated to wall clock against the buffer's start).
    #expect(first.0 >= Instant(secondsSinceEpoch: startEpoch))
    #expect(first.1 <= Instant(secondsSinceEpoch: startEpoch + 0.5).advanced(by: 0.0001))
  }

  @Test("live vad events publish coarse state transitions only, never per-buffer repeats")
  func publishesVADStateTransitions() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: startEpoch))
    let recorded = Mutex<[EarsEvent]>([])
    let actor = try makeActor(
      dataRoot: dataRoot, clock: clock,
      buffers: [
        makeBuffer(seconds: 0.5),  // speech: published
        makeBuffer(seconds: 0.5),  // still speech: not re-published
        makeBuffer(seconds: 0.5, value: 0.0),  // silence: published
        makeBuffer(seconds: 0.5, value: 0.0),  // still silence: not re-published
        makeBuffer(seconds: 0.5),  // speech again: published
      ],
      chunkSeconds: 30,
      eventSink: { event in recorded.withLock { $0.append(event) } })

    try await actor.start()
    await actor.drainForTesting()

    // Each transition is stamped on the buffer-derived timeline: speech at the
    // first speech span's start (0 within its fully-voiced buffer), silence at
    // its buffer's start. (`source` runtime-state events also flow through the
    // sink in v2 — filtered out here, this test is about vad coarseness.)
    #expect(
      recorded.withLock { $0 }.filter { $0.kind == .vad } == [
        .vad(source: "mic", state: .speech, t: Instant(secondsSinceEpoch: startEpoch)),
        .vad(source: "mic", state: .silence, t: Instant(secondsSinceEpoch: startEpoch + 1.0)),
        .vad(source: "mic", state: .speech, t: Instant(secondsSinceEpoch: startEpoch + 2.0)),
      ])
  }

  @Test("the initial silence baseline is not announced to the live feed")
  func initialSilencePublishesNothing() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: startEpoch))
    let recorded = Mutex<[EarsEvent]>([])
    let actor = try makeActor(
      dataRoot: dataRoot, clock: clock,
      buffers: [makeBuffer(seconds: 0.5, value: 0.0), makeBuffer(seconds: 0.5, value: 0.0)],
      chunkSeconds: 30,
      eventSink: { event in recorded.withLock { $0.append(event) } })

    try await actor.start()
    await actor.drainForTesting()

    #expect(recorded.withLock { $0 }.filter { $0.kind == .vad }.isEmpty)
  }

  @Test("pause/resume re-announces speech instead of assuming continuity across the gap")
  func resumeReannouncesVADState() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: startEpoch))
    let recorded = Mutex<[EarsEvent]>([])
    // SyntheticCaptureBackend replays its script on every start(), so the
    // resumed generation delivers speech again.
    let actor = try makeActor(
      dataRoot: dataRoot, clock: clock,
      buffers: [makeBuffer(seconds: 0.5)],
      chunkSeconds: 30,
      eventSink: { event in recorded.withLock { $0.append(event) } })

    try await actor.start()
    await actor.drainForTesting()
    try await actor.pause()
    clock.advance(by: 10)
    try await actor.resume()
    await actor.drainForTesting()

    let events = recorded.withLock { $0 }.filter { $0.kind == .vad }
    #expect(events.count == 2)
    for event in events {
      guard case .vad(let source, let state, _) = event else {
        Issue.record("expected only vad events, got \(event)")
        continue
      }
      #expect(source == "mic")
      #expect(state == .speech)
    }
  }

  @Test("start() while already capturing throws alreadyCapturing")
  func startTwiceThrows() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: startEpoch))
    let actor = try makeActor(
      dataRoot: dataRoot, clock: clock, buffers: [makeBuffer(seconds: 0.5)], chunkSeconds: 30)

    try await actor.start()
    await #expect(throws: CaptureActorError.alreadyCapturing) {
      try await actor.start()
    }
    await actor.stop()
  }

  @Test("stop() flushes an in-progress partial chunk rather than losing it")
  func stopFlushesPartialChunk() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: startEpoch))
    // chunkSeconds 30 so the single 0.5s buffer never rolls over on its own.
    let actor = try makeActor(
      dataRoot: dataRoot, clock: clock, buffers: [makeBuffer(seconds: 0.5)], chunkSeconds: 30)

    try await actor.start()
    await actor.stop()

    #expect(try chunkEvents(dataRoot: dataRoot).count == 1)
  }

  @Test("flush() finalizes the in-progress chunk and keeps capturing")
  func flushFinalizesAndContinues() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: startEpoch))
    // Three 0.5s buffers @ chunkSeconds 1.0: the first two roll into one
    // chunk, the third is a 0.5s partial still pending after the stream ends.
    let actor = try makeActor(
      dataRoot: dataRoot, clock: clock,
      buffers: [makeBuffer(seconds: 0.5), makeBuffer(seconds: 0.5), makeBuffer(seconds: 0.5)],
      chunkSeconds: 1.0)

    try await actor.start()
    await actor.drainForTesting()

    #expect(try chunkEvents(dataRoot: dataRoot).count == 1)

    try await actor.flush()

    #expect(try chunkEvents(dataRoot: dataRoot).count == 2)
    #expect(await actor.status().state == .capturing)
  }

  @Test("flush() with nothing pending adds no new events")
  func flushNoOp() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: startEpoch))
    let actor = try makeActor(
      dataRoot: dataRoot, clock: clock, buffers: [makeBuffer(seconds: 0.5)], chunkSeconds: 1.0)

    try await actor.start()
    await actor.drainForTesting()
    try await actor.flush()  // finalizes the single pending 0.5s buffer
    let afterFirstFlush = try indexEvents(dataRoot: dataRoot).count
    try await actor.flush()  // nothing pending now
    #expect(try indexEvents(dataRoot: dataRoot).count == afterFirstFlush)
    await actor.stop()
  }

  @Test("pause() then resume() records one gap covering the paused window")
  func pauseResumeRecordsGap() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: startEpoch))
    let actor = try makeActor(
      dataRoot: dataRoot, clock: clock, buffers: [makeBuffer(seconds: 0.5)], chunkSeconds: 30)

    try await actor.start()

    clock.set(Instant(secondsSinceEpoch: startEpoch + 100))
    try await actor.pause()
    #expect(await actor.status().state == .paused)

    clock.set(Instant(secondsSinceEpoch: startEpoch + 160))
    try await actor.resume()
    #expect(await actor.status().state == .capturing)

    let gaps = try indexEvents(dataRoot: dataRoot).compactMap { event -> (Instant, Instant)? in
      if case .gap(let start, let end, _) = event { return (start, end) }
      return nil
    }
    #expect(gaps.count == 1)
    let gap = try #require(gaps.first)
    #expect(gap.0 == Instant(secondsSinceEpoch: startEpoch + 100))
    #expect(gap.1 == Instant(secondsSinceEpoch: startEpoch + 160))

    await actor.stop()
  }

  @Test("resume() re-anchors the chunk timeline to wall clock across a pause gap")
  func resumeReanchorsTimelineAcrossGap() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: startEpoch))
    // chunkSeconds == buffer length, so each captured buffer rolls exactly one
    // chunk; SyntheticCaptureBackend replays its script on every start(), so the
    // resumed generation delivers another buffer's worth of audio to encode.
    let actor = try makeActor(
      dataRoot: dataRoot, clock: clock,
      buffers: [makeBuffer(seconds: 0.5)], chunkSeconds: 0.5)

    try await actor.start()
    await actor.drainForTesting()

    // Pause 100s of wall-clock in, resume 60s after that — a gap the
    // sample-derived timeline would otherwise swallow whole.
    clock.set(Instant(secondsSinceEpoch: startEpoch + 100))
    try await actor.pause()
    clock.set(Instant(secondsSinceEpoch: startEpoch + 160))
    try await actor.resume()
    await actor.drainForTesting()
    await actor.stop()

    let starts = try chunkEvents(dataRoot: dataRoot).compactMap { event -> Instant? in
      if case .chunk(let start, _, _, _) = event { return start }
      return nil
    }
    // The pre-gap chunk anchors at start; the post-gap chunk must land at the
    // resume instant (startEpoch + 160), re-tied to wall clock — not continue
    // the frozen timeline at ~startEpoch + 0.5, which is the ~gap-duration
    // drift this fix removes.
    #expect(starts.contains(Instant(secondsSinceEpoch: startEpoch)))
    #expect(starts.contains(Instant(secondsSinceEpoch: startEpoch + 160)))
    #expect(
      !starts.contains {
        $0 > Instant(secondsSinceEpoch: startEpoch)
          && $0 < Instant(secondsSinceEpoch: startEpoch + 100)
      })
  }

  @Test("pause() is idempotent and records only one gap across a double pause")
  func pauseIsIdempotent() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: startEpoch))
    let actor = try makeActor(
      dataRoot: dataRoot, clock: clock, buffers: [makeBuffer(seconds: 0.5)], chunkSeconds: 30)

    try await actor.start()
    clock.set(Instant(secondsSinceEpoch: startEpoch + 100))
    try await actor.pause()
    clock.set(Instant(secondsSinceEpoch: startEpoch + 120))
    try await actor.pause()  // no-op: already paused, pause window unchanged

    clock.set(Instant(secondsSinceEpoch: startEpoch + 160))
    try await actor.resume()

    let gaps = try indexEvents(dataRoot: dataRoot).compactMap { event -> (Instant, Instant)? in
      if case .gap(let start, _, _) = event { return (start, start) }
      return nil
    }
    #expect(gaps.count == 1)
    #expect(gaps.first?.0 == Instant(secondsSinceEpoch: startEpoch + 100))
    await actor.stop()
  }

  @Test("resume() without a preceding pause throws notPaused")
  func resumeWithoutPauseThrows() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: startEpoch))
    let actor = try makeActor(
      dataRoot: dataRoot, clock: clock, buffers: [makeBuffer(seconds: 0.5)], chunkSeconds: 30)

    try await actor.start()
    await #expect(throws: CaptureActorError.notPaused) {
      try await actor.resume()
    }
    await actor.stop()
  }

  @Test("status() reflects the capture lifecycle transitions")
  func statusReflectsTransitions() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: startEpoch))
    let actor = try makeActor(
      dataRoot: dataRoot, clock: clock, buffers: [makeBuffer(seconds: 0.5)], chunkSeconds: 30)

    #expect(await actor.status().state == .disabled)
    #expect(await actor.status().codec == "aac")

    try await actor.start()
    #expect(await actor.status().state == .capturing)

    clock.set(Instant(secondsSinceEpoch: startEpoch + 10))
    try await actor.pause()
    #expect(await actor.status().state == .paused)

    clock.set(Instant(secondsSinceEpoch: startEpoch + 20))
    try await actor.resume()
    #expect(await actor.status().state == .capturing)

    await actor.stop()
    #expect(await actor.status().state == .disabled)
  }

  @Test("status() surfaces the source id and this run's chunk bounds")
  func statusReportsChunkBounds() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: startEpoch))
    let actor = try makeActor(
      dataRoot: dataRoot, clock: clock,
      buffers: [makeBuffer(seconds: 0.5), makeBuffer(seconds: 0.5)], chunkSeconds: 1.0)

    try await actor.start()
    await actor.drainForTesting()

    let status = await actor.status()
    #expect(status.id == "mic")
    #expect(status.oldestChunkStart == Instant(secondsSinceEpoch: startEpoch))
    let newest = try #require(status.newestChunkEnd)
    #expect(abs(newest.interval(since: Instant(secondsSinceEpoch: startEpoch + 1.0))) < 0.001)
    #expect(status.bytesUsed > 0)
  }

  @Test("status() reports .error when a stats-reporting backend has failed")
  func statusReflectsBackendFailure() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: startEpoch))
    let backend = FailingStatsBackend(source: "mic", buffers: [makeBuffer(seconds: 0.5)])
    let actor = try makeActor(
      dataRoot: dataRoot, clock: clock, buffers: [], chunkSeconds: 30, backend: backend)

    try await actor.start()
    await actor.drainForTesting()
    await backend.markFailed()

    #expect(await actor.status().state == .error)
    await actor.stop()
  }

}

/// A stats-reporting synthetic backend whose failure latch is test-controllable,
/// so ``CaptureActor/status()``'s health-surfacing path can be exercised without
/// real Core Audio backpressure.
private actor FailingStatsBackend: CaptureStatsReporting {
  nonisolated let source: SourceID
  private let buffers: [AudioBuffer]
  private var failed = false

  init(source: SourceID, buffers: [AudioBuffer]) {
    self.source = source
    self.buffers = buffers
  }

  var stats: CaptureStats {
    CaptureStats(droppedSampleCount: 0, hasFailed: failed)
  }

  func markFailed() { failed = true }

  func start() async throws -> AsyncStream<AudioBuffer> {
    let buffers = self.buffers
    return AsyncStream { continuation in
      for buffer in buffers { continuation.yield(buffer) }
      continuation.finish()
    }
  }

  func stop() async {}
}

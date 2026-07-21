import EarsCaptureKit
import EarsCore
import EarsCoreTestSupport
import EarsDataStore
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
  /// 0.02 energy threshold, so a full-value buffer classifies as speech).
  private func makeBuffer(seconds: Double, value: Float = 0.5) -> AudioBuffer {
    AudioBuffer(
      samples: [Float](repeating: value, count: Int(seconds * Double(nativeRate))),
      sampleRate: nativeRate)
  }

  private func makeActor(
    dataRoot: URL,
    clock: ManualClock,
    buffers: [AudioBuffer],
    chunkSeconds: Double = 1.0,
    timeCapSeconds: Int = 7_200,
    backend: (any CaptureBackend)? = nil,
    eventSink: EventSink? = nil
  ) throws -> CaptureActor {
    let descriptor = makeDescriptor(timeCapSeconds: timeCapSeconds)
    let indexAppender = IndexAppender(
      fileURL: DataStoreLayout.indexFile(dataRoot: dataRoot, sourceID: descriptor.id))
    let encoder = try ChunkEncoder(
      sourceID: descriptor.id,
      dataRoot: dataRoot,
      codec: descriptor.codec,
      bitrate: descriptor.bitrate,
      nativeSampleRate: nativeRate,
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
      vad: EnergyVAD(),
      clock: clock,
      eventSink: eventSink
    )
  }

  private func indexEvents(dataRoot: URL) throws -> [IndexEvent] {
    let indexURL = DataStoreLayout.indexFile(dataRoot: dataRoot, sourceID: "mic")
    guard FileManager.default.fileExists(atPath: indexURL.path) else { return [] }
    let contents = try String(contentsOf: indexURL, encoding: .utf8)
    let parsed = IndexLog.parse(contents)
    #expect(parsed.malformedLines.isEmpty)
    return parsed.events
  }

  private func chunkEvents(dataRoot: URL) throws -> [IndexEvent] {
    try indexEvents(dataRoot: dataRoot).filter {
      if case .chunk = $0 { return true } else { return false }
    }
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

  @Test("status() surfaces the source id and reports a bounded ring window")
  func statusReportsRingWindow() async throws {
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

  @Test("an aged-out chunk is evicted and logged on the next rollover")
  func agedChunkEvicted() async throws {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: startEpoch))
    // A zero time cap so every finalized chunk is immediately aged out; four
    // 0.5s buffers roll two chunks, and the eviction pass run on the second
    // rollover deletes the first.
    let actor = try makeActor(
      dataRoot: dataRoot, clock: clock,
      buffers: [
        makeBuffer(seconds: 0.5), makeBuffer(seconds: 0.5),
        makeBuffer(seconds: 0.5), makeBuffer(seconds: 0.5),
      ],
      chunkSeconds: 1.0, timeCapSeconds: 0)

    // Advance the clock well past the anchor so the first chunk's end is
    // strictly before `now - timeCap` when the second chunk rolls over.
    clock.set(Instant(secondsSinceEpoch: startEpoch + 10_000))
    try await actor.start()
    await actor.drainForTesting()

    let evicts = try indexEvents(dataRoot: dataRoot).filter {
      if case .evict = $0 { return true } else { return false }
    }
    #expect(!evicts.isEmpty)
  }

  @Test("chunks written by a previous daemon run are evicted on start once past the cap")
  func priorRunChunksEvictedOnStart() async throws {
    let dataRoot = try makeDataRoot()

    // First run: write chunks under a generous cap so none are evicted yet.
    let clock1 = ManualClock(Instant(secondsSinceEpoch: startEpoch))
    let actor1 = try makeActor(
      dataRoot: dataRoot, clock: clock1,
      buffers: [
        makeBuffer(seconds: 0.5), makeBuffer(seconds: 0.5),
        makeBuffer(seconds: 0.5), makeBuffer(seconds: 0.5),
      ],
      chunkSeconds: 1.0, timeCapSeconds: 7_200)
    try await actor1.start()
    await actor1.drainForTesting()
    await actor1.stop()

    let priorChunks = try chunkEvents(dataRoot: dataRoot)
    #expect(!priorChunks.isEmpty)
    let evictsBefore = try indexEvents(dataRoot: dataRoot).filter {
      if case .evict = $0 { return true } else { return false }
    }
    #expect(evictsBefore.isEmpty)

    // Second run: a fresh actor (empty `knownChunks`) over the SAME data root,
    // clock advanced well past the cap so every prior chunk is aged out. The
    // seed-from-index pass in start() must find and evict them immediately,
    // before any new chunk rolls over — this is the restart-persistence bug.
    let clock2 = ManualClock(Instant(secondsSinceEpoch: startEpoch + 100_000))
    let actor2 = try makeActor(
      dataRoot: dataRoot, clock: clock2, buffers: [], chunkSeconds: 1.0, timeCapSeconds: 7_200)
    try await actor2.start()
    await actor2.drainForTesting()

    let evictedFiles = Set(
      try indexEvents(dataRoot: dataRoot).compactMap { event -> String? in
        if case .evict(let file, _) = event { return file } else { return nil }
      })
    let priorChunkFiles = Set(
      priorChunks.compactMap { event -> String? in
        if case .chunk(_, _, let file, _) = event { return file } else { return nil }
      })
    #expect(evictedFiles == priorChunkFiles)

    // And the on-disk chunk files are actually gone.
    let sourceDir = DataStoreLayout.sourceDirectory(dataRoot: dataRoot, sourceID: "mic")
    for file in priorChunkFiles {
      let path = sourceDir.appendingPathComponent(file).path
      #expect(!FileManager.default.fileExists(atPath: path))
    }
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

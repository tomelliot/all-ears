import EarsCaptureKit
import EarsCore
import EarsCoreTestSupport
import EarsDataStore
import Foundation
import Testing

@testable import EarsDaemonKit

/// CI-shaped proxy for `docs/roadmap.md`'s Phase 1 exit criterion: "daemon
/// runs for days at a flat memory baseline; buffer stays bounded; gaps
/// recorded across restarts, sleep/wake, and device unplug." Literal
/// multi-day soak testing cannot run in CI, so this suite instead drives a
/// real ``CaptureActor`` through hundreds of accelerated chunk/rollover/
/// eviction cycles — a ``SyntheticCaptureBackend`` scripted with many
/// buffers, consumed with a ``ManualClock`` jumped forward so eviction
/// behaves exactly as it would if the whole run had unfolded in real time —
/// in well under a second of wall-clock time.
///
/// **This is a proxy, not a proof.** It does not and cannot demonstrate flat
/// *memory* over multiple real days, nor real restarts/sleep/wake/device
/// unplug (`CaptureActorTests`/`EarsDaemonTests` separately cover gap
/// recording with real event assertions using a handful of cycles). Real
/// multi-day validation of the roadmap criterion is a manual operational
/// step, not something any suite here can substitute for — see
/// `docs/operations/capture-soak-runbook.md` for the actual procedure (what
/// to run, how long, what to watch on a real machine).
@Suite("Soak proxy")
struct SoakProxyTests {
  private let nativeRate = 48_000
  private let asrRate = 16_000
  private let startEpoch = 1_000.0
  private let chunkSeconds = 1.0
  private let timeCapSeconds = 5
  /// Chunks whose end lands within this many seconds of "now" survive
  /// eviction; a chunk's own duration plus one extra chunk of slack covers
  /// rounding at the retention boundary and any still-in-flight partial.
  private var expectedMaxRetainedChunks: Int { timeCapSeconds + 2 }

  private struct SoakResult {
    var chunkFileCount: Int
    var bytesUsed: Int
    var indexedChunkEventCount: Int
  }

  private func makeDataRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SoakProxyTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func makeDescriptor() -> SourceDescriptor {
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
  /// energy threshold, matching ``CaptureActorTests``'s convention).
  private func makeBuffer(seconds: Double, value: Float = 0.5) -> AudioBuffer {
    AudioBuffer(
      samples: [Float](repeating: value, count: Int(seconds * Double(nativeRate))),
      sampleRate: nativeRate)
  }

  /// Runs `cycles` accelerated chunk cycles (two 0.5s buffers per cycle,
  /// rolling one 1.0s chunk) through a single, persistent ``CaptureActor``,
  /// then reports the *physical* on-disk ring-buffer footprint plus the
  /// append-only index's chunk-event count, so the caller can distinguish
  /// "bounded ring buffer" from "ever-growing log" (both are expected, but
  /// only the former is the roadmap criterion this proxy targets).
  ///
  /// The clock is jumped once, to the instant the whole synthetic run would
  /// have ended in real time, *before* `start()` — equivalent to asking
  /// "what does the ring buffer look like right now, after this many cycles
  /// of real elapsed time have passed," without spending any real wall-clock
  /// time getting there. Every eviction pass during the drain therefore sees
  /// the same final `now`, so chunks older than `timeCapSeconds` are evicted
  /// as soon as they roll — exactly the steady-state a long-running daemon
  /// converges to.
  private func runSoak(cycles: Int) async throws -> SoakResult {
    let dataRoot = try makeDataRoot()
    let clock = ManualClock(Instant(secondsSinceEpoch: startEpoch))
    let descriptor = makeDescriptor()
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

    let buffers = (0..<(cycles * 2)).map { _ in makeBuffer(seconds: 0.5) }
    let backend = SyntheticCaptureBackend(source: descriptor.id, buffers: buffers)
    let actor = CaptureActor(
      descriptor: descriptor,
      dataRoot: dataRoot,
      backend: backend,
      encoder: encoder,
      indexAppender: indexAppender,
      vad: EnergyVAD(),
      clock: clock
    )

    // Jump to "now" as of the end of this many cycles' worth of real elapsed
    // time -- see the doc comment above for why a single jump (rather than
    // ticking the clock per buffer) already exercises the converged
    // steady-state eviction behavior.
    clock.set(Instant(secondsSinceEpoch: startEpoch + Double(cycles) * chunkSeconds))

    try await actor.start()
    await actor.drainForTesting()
    await actor.stop()

    let chunkFileCount = countFiles(
      in: DataStoreLayout.chunksDirectory(dataRoot: dataRoot, sourceID: descriptor.id))
    let bytesUsed = await actor.status().bytesUsed

    let indexURL = DataStoreLayout.indexFile(dataRoot: dataRoot, sourceID: descriptor.id)
    let contents = try String(contentsOf: indexURL, encoding: .utf8)
    let parsed = IndexLog.parse(contents)
    #expect(parsed.malformedLines.isEmpty)
    let chunkEventCount = parsed.events.filter {
      if case .chunk = $0 { return true } else { return false }
    }.count

    return SoakResult(
      chunkFileCount: chunkFileCount, bytesUsed: bytesUsed, indexedChunkEventCount: chunkEventCount)
  }

  private func countFiles(in directory: URL) -> Int {
    (try? FileManager.default.contentsOfDirectory(atPath: directory.path).count) ?? 0
  }

  @Test(
    "bounded synthetic soak: ring/tracked-chunk state stays flat across many accelerated cycles (CI proxy for the roadmap's real multi-day criterion)"
  )
  func boundedAcrossManyAcceleratedCycles() async throws {
    let small = try await runSoak(cycles: 20)
    let large = try await runSoak(cycles: 200)

    // The physical ring buffer (files actually on disk, and the bytes they
    // occupy) converges to roughly `timeCapSeconds / chunkSeconds` retained
    // chunks once eviction has run -- independent of how many total cycles
    // preceded it. If `CaptureActor`'s tracked-chunk/eviction bookkeeping
    // leaked (grew with cycle count instead of staying flat), the 10x-more-
    // cycles run would show a proportionally larger file count and byte
    // footprint; it does not.
    #expect(small.chunkFileCount <= expectedMaxRetainedChunks)
    #expect(large.chunkFileCount <= expectedMaxRetainedChunks)
    #expect(large.chunkFileCount <= small.chunkFileCount + 2)
    #expect(large.bytesUsed <= small.bytesUsed * 3)

    // Sanity: real rollovers actually happened across both runs (the bound
    // above isn't trivially true because nothing ran) -- the append-only
    // index log's chunk-event *count* is expected to keep growing with cycle
    // count (that's the log, a documented ever-growing history, not the ring
    // buffer); only the physical buffer asserted above is the roadmap's
    // "buffer stays bounded" criterion.
    #expect(small.indexedChunkEventCount > 0)
    #expect(large.indexedChunkEventCount > small.indexedChunkEventCount * 5)
  }
}
